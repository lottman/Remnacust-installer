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
HELPER_BUNDLE_SHA256='abecdd4375328411c723d6d0a2a5ba97cf38655aafdbaeaed5fbe5fb0008cd00'
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
# DATA d4kKa80abI4N78773h/+fZD9bxTwf4P7v7ugneXtf1BF/mD//9vW//0Ma0UEU18duphLwpuU/8XSQclksiSNo+qnoxHVSGN68sMU
# DATA 7xG8r+4vX8+pvsXz+TRVXy5/lszUZ7zoZpwM1dck/d2LA18tF8lY1wcO5uin0F/jycz+ziWDMT/hZHfvDG+9KHKYlbznx8dn+yeY
# DATA nFH6Zvp9/2T/xdHu3qvTs8EX+4cv909OB182voFm+0fPqM33ffg0WNdq92jvi+MTutGcXLV4Qmw+3Ch/Oqn8ObccfPbq6Nnh/uD0
# DATA i11gszsl+xaQ0g82Kt7zg8P9U0xHKeU3eInzPEVVxW+2WyLvNC/6zVET7MuLS8Ziw3e0IUu3R47Vp5ws0S0t21u58G3Lyxkop+eu
# DATA QDizRl6vA6481eoYoaXAUYK/O9YxTciS0Hyn5YpRoickBpzz3TKl8Hfxk+FH7bEqVbwXuz8ZnOx+haXlu24RDXqECw7PmrlHuZNl
# DATA URkXW9U1xMrcURwCHGWnIoZEhui5uuJkyJebVInAdZk6ua3E6lTelW1bkyO+1AAzqtVlufK+SO/B61jdtrztrS1KV6JaU+o/5U+3
# DATA N63TD/j9vLZ5Yf9U+bjyaUnFSO894yD3FwjzEqh0cSbM1x/gDQmxus5DEjUx7LOgqyPLpU11iIZyL0YJHxFbLGewebHGOIZWMMIr
# DATA pRexHlGSATqwniNXjik3uE5Rxbuv+oA6u2mgUaU7ayXdtbOODAPeSZPw0bG5/Qre+ou4HqbpuGw6hV+tmehS2UAqtOkEnSwRdmwC
# DATA 48dqFXmHhpjSVGYeWfF/5DfuW4xn+mY+WY5Rmi7iuTmjJLwWi45MnTAbfa1Ke1/Ok8tUZfB82UNuW4unEWfvAFt+MMf4wNzOVASh
# DATA WigSh8lUHp5vb+KpHuz/gkHC50UllBGsMj60s4pQZDzbPdv1S1JB0d4Y+HBvd++Lfd+WA7RB1PdW8472AvZbqTzmZP2rafxmxveG
# DATA OLP05aoisx44LxZZulIOEwFlFt671i/kQkajY8hYwTQEBcLlR7ycc7w8fFZmNuR/wvxI6FNB7NCovJ2D0CLlynldlqQ83ChtVM4b
# DATA F5otUnEoze50Qss9A4BAgW6KxfQGwVsvAXfutvEzDFe1d5Wpkxyo6imT4E0yWU52FJM3HPLBgpv5o+Wr+P+CsU2nHbBiGOakLMfB
# DATA nGo6mDP+1qFzpEYeIJ3BupeA+Cp+kGGzOJiYsegKvB35mU4hlGUm0GfDoR0SDsAV5Pkj4KVaZ4s09ceYaeNSSV7W6esWuE5GeR5Y
# DATA lyzg8PgDjN5q9rpbj8GVdLQyvszYOueGPevjzrGISdwTb0tsxdId2iJsqljF34ThSrpWxx1dVwqvnqu3Lh7cV6+m2XI2o2xUtaMU
# DATA 3KXKv76EZejUTC6+vawthsrRbtVoDrI+aEgWWnThuFvthTtmrDsle6zSU/RUVZ6S/YZrSwq3PlXIJVHU0U75hjR2P5h5ucJWVKni
# DATA ualySgXgUzkraWPFSMTVMydENy9gjeGn2e1fgoZf+UtROv+SNc5vQOWsyNHRR4hDB7sIFNXMWZG1Fha5WIVGIqKM1BbZHHoHkHOJ
# DATA d8DDdIE9mOoxHwq3ypl14cbkpDJ3zLBgTnYm5w4XCq66/0PfaYR0oBj2B8KBhfLMbsiWE3d4RwdkAlB1O5DCxEp4BB9j2lrHRXEr
# DATA WLKIK8VLQhmwtaqUJZOyiY4cfIurv80ijE7P6+pMfFpHFzmjs+VygOdtsdkjl41J2uNqlR77DJDD4fU2vlOWhtxXVxYlkSZhVy4S
# DATA 9u30oiv+stVCkgLrFLlqBvFnbpFXEKh5Eb+6nw+4DhfEk8MQ/CjlImq4D0qOiBFW89GOFjgaE/efZ17V9vhi8TWsx+l5lQXpyy9t
# DATA cUyt+chKZaXevNx/iZC79G4hd6VNcaWo9SSvrmac4H2lgDvrotM1xK+v21shG2Bf5jyHTP0eIjPFo/VLBcm3Kx3gJrJegU2gfFFV
# DATA 1lgqVXuDWk1p9Eq+OIaUQjQwrKl/Zo50y0riHv34Y5m5gmEbx7hbXX59DtEF3Tl+JynTnF5Pi122aEWtdSXfXlWB6yKoovVPhnEU
# DATA 5bR+S6nO2Y1yZjxnO+Yr8N1jRFZBfwUbwbboxBjGQSNy8JX4nks0t8572xcFBqFjBNI2WG/yOcqRGkaUC/mKzL+7rrjqeqGjcFcg
# DATA fX6WyEl89tTWht22WEUyZFWTq5WvS/YBOnBrn8N/8Pgy7ft0+NOdJK19hut8cFzmviuFlgOQVM5wUK6vvOEgmvsjZN6+O81sRewp
# DATA FVDOLNMsxDXMhk7BJHB4Pl2wU5pvsxkkGdgGlglimFxBquIgULH8WF5hg/KAdMXWQ1ztDOYA4uo2v4hZzhHBnZKI5O4LXQ78DMxG
# DATA qfSrX6xJ6V7tZTRPlOhl7GGNkSclM05NVx755pv8z4/zQOA14yskKngs5U+6oHCxRriwUB6/IV89zYybVJiy1A0dNwNt1u2IVjVL
# DATA Z2XF5yrruLt+zWHz6qqm1edapZpG8bxIpoQBCCm7Gt5DIiVdLmZLOjdgCLPyAA3zO4p0b9ZQbqEMkBOOD4mCvFdrOkr5oBEBcxbM
# DATA D+CX8qo+hw2J3qr8ESFUHzFi4e842kLVB0HQbsOfomM5mN1PS47vV20EudLF4tua0/FvZWJkaJXN4ywrM95wA5PKjRUVCKqduq6o
# DATA LUKDBYWu2oaL+pB99qDrjnr5UKuGXvJz9piA+QlHothzSAVRsHFNpq5cX9rFln9TRJwRU3gjL6PyPAH6frNN/0WuXa9fqG7YfqEH
# DATA eAQqmF7G6B23JVkVX3DrSVrSHDpSUGAQTelpXL+co1xip1B7ey+t81ZrR7Uy7cwtC7pghfZQPtGfauhA4AIbrL9UNDuh2J3YP87b
# DATA pQINTpFJzoDR7hTUd3VPX+6fnB4cH6mBubJHjX2ij3H1Sa9SSIyjGeq3ArNCy8WcUWdZcx9kwrmY4LuDHmPEPYYV2m5i+6kiEbxZ
# DATA myptqPNMThXQNQvsEA6RoSmr4qz6d40pcjgJYmT9Hksmtr2rXZGYUGO8kduq07xbcnutqevWPNaFhgUfb0srHWgmLrbetsPb7+4V
# DATA QI7rq3J3Z228snXbA06ySu9giFHd64TsZ7rYaepL3RXPk3LIKy4Atf6PdPFb7gLds/b2WzYJn9q2DCDr2f2so+K8RnCqGyGptdoi
# DATA 7C8Q2TFgtshSTPlsDK8S38Ia/qTI2zI2VecaTY8wf+lGNi5zNC8bqKw73ijO/M2bep0jXabNmjpAjxSB5qSaujhJ98sm8D1Xf4mm
# DATA BPZxpyOn+5SBa7oBxFnr7j1UGGflBLhpXBTSWVt/8dFouIynsbrsxsvdurrqc9AHqe91N6jyk66nQZ0B1Of+7MOABWcAuQTXS1Cx
# DATA 4vk1F9qKAswIiSyga75UivMpcSSDXXorV91QPcxcb5KkhDvsqS85DHQFA8ALui4s1YiKaC5MDpMhkVpB+aL8Wpdtn+D99eNE31tP
# DATA CjHmGgXEYagcmEpCQsrEzxiWHyVvdko1MfA2MQqSzHesDVRZT1m/ozNH1xw3cIo8cpiQ4tuPeU87cdptt71uaqr9qy13b+mENNNn
# DATA 71UPxUU7hDaFNNHuifFD4U3N9KRGmWnKafSWvtX2939ycApbQr6BCN9/8fLs67t7SqysPPm+vzulu5as4Dde3zRbDsdJdkXbIENZ
# DATA b/aAul/0KskKupvN0xCsFDyMT+VDFrBl4iUwBb7Sz1fBJZXYgcUfJE2vaPa/CzO6nyEBpajj7gW8ieuhEO6LLoj+12VVhfUxcPKa
# DATA DtcXSHCa5dFknsjtFeYelY9sTmL9rpCr30R6dirLmO3/aJyLD0V594A0kIVKpl1BJRhOjqzNJ4t5bG0m29fgqh5rPRlCJLThndcd
# DATA D66dpkQv6HA9mJaV30vhgXSmaM0uHYDWAdVTwxhBqar1rgcKBuRrGNzbmLD06NYS/H10c6SpD4OHF2S1+QOlDVQ1A41IqhZBCDRk
# DATA SdaWrjsgavS4+FXGufWuY8yvdGIXPOCSBUrrpaaSJmQZaLrqAeur/MXSiBkkVosrDxfCYNr8/8kZg3zq7Xef/99oNFuNlfz/evcP
# DATA +f/fxb+NjY2TGCtU+dlyRhfWxJFVGZlzuKWWdYBOAUwIjaBxiMrGaDm276a9J92f0vU/IEl/ORR9Rv9yqz+iz9XzTvZfHp8enB2f
# DATA HFCmOx9IkhIw6G+4vArntSR9Mk4XCzDpn5gLbHWZmJWf8tc2re9jtbKM01/BzSvcOZemuR8+Vb0m9wv0cOfxbYg0YWuuV4vFLNt+
# DATA 8uQS9ITlED3WutuT3BzvnEkacB7VBcNx5x282P0cawPmziiIj2f7vL7ZDzZHnJhT8Z7t7z47PDjC/HSKr6ogyCzNEqp0pG80MJl5
# DATA pT8uOVe+rURqzUXUksv8xyUKzKoi5flWc2m2rZspMID6g/EAy2WXmdwx1TtdUDbE6i0suryOdecQvYbg8vuWq1+nUGOEBh9yMceD
# DATA iG9RzMcEFF6tyIDpglREq0e+V4DhfOCWGuc21LIFyAkswllwmZnqnp+sPH9Glq5pYir23qDP8Rw6lxJnI/eWPi6RaK8yVXazN+65
# DATA Ru/FhY0M6DpfRPjykoqZSXcJO1vz3Vtw0AElJiRzf+Bdzk9AvA9VYjS3yBrAkegqXAt0PxhnKVMKWVaZuHrg9yTI4qyW63X3OgU7
# DATA J8heY8/PqKgeeiS4AzxTRe9BR/5PMfOWf4+w43g8cjsrxnHh3Dgx3MWHPC3A3kVB0ShVmdEiOkwZxxMeSbioIftGNypeZVyp2B6f
# DATA sY5pqbXfXnMbpkVbj7xkI51fUvjSXA5S407kOtJ1d2jCtIVZWkRWdG/m2pmfmy8XbjyKX1KHYGiByx+jGlklQTdgZTKXHYd6I9+b
# DATA 0KojnJotOvd66183Sc7VJikgFj3tZesaGdXVD3f8et4VesbFIZXRTaxJ9DuQ1UFEaSigHoP+G5nbWMh1sGPJ3dp8OS2fS0lILHOH
# DATA 07uochKVuEXDYLbAK5RluvwjxhrURwZlZwIKc6teNYBXnDwONWK2iKA1ZbK0H5/KIvsLlgTWGJ6hiyeOMj3ncTJJFm52o5WjnR8b
# DATA QLJWkJfEbSOrPkTuDNYFZ1+qu+v4xiq+ptMJbkozjm2a6dwm8Tjiw0RYzx/e3Ob3OWoqY2E1vwHLFmUUJ1QAXkivpCoVBlyaUJcC
# DATA d5KM1FKzxFi5vu1yni7pBgI1MxjCvjRPvahvn5axwfjCzMH8FSxv39aI9u4wNfdj6twFx1kR3bt7ZWDZKl7IVTKlMO3rOJ4JcHh9
# DATA ALBttW/oN0vjyG8ixGyzvoILB8WKOK0hLetUUgIzN9mfPLfWC07k7b5caN0fs9oHI/wvpaK/VZdcdYGcJGEvm33fan7lOHlSFe62
# DATA E4o1LOuvwXVvYrYTuTGkXKTA4FE31nomoieXKtYV5FpmIAC4rtsPQh7lwNakqAYwNKl7dzkzJawVHdgrkHYrvY+Ld5uqFboAzhnm
# DATA 9p7L8Kwh6TgcWr33sTid6SXmGM59mC6nZKs5vjxp4GinBRvbDG/pqnxcF29sA0F4D0p5M6/Fp9JmdiQrZ+RorVVHP5x+sPqtPK/5
# DATA Xf2jHb3pt4uKWp5omSkoAsaDmyfaXi8c2Ze5A5Ynsv54PndVjSG0e31vQM9V1gu4+IPXiH/f1+JtBO8jyjbRp88WRxSPY7QwnwJP
# DATA 8amMbVWxwxkQISXfSfV3V6tcWd35hCrZmrvsc9ohL+knO37jcWE+S4841R+LAn+yPKymmDWRWYfpcswX0KEbe3yrVOhksW5xuL9R
# DATA aQ8XFUB+K7Df2f4NbdAKMTzV9Xfp3nHFYHOUUqp8G+f0B5extc2jDymJy7IHI4N8mdGOsi/XtEdWaxW4ZQXYel1Zeg94g5WkdgvL
# DATA ilNV3XZGX0hm/wdzr/778P9mvyfH7+PqvzR7jZbr/633Or0/1H/9rvy/X0pUVecDCt+Ti7zY6So+ElS3Fqmw5/v8vbm6Lfe6f6v+
# DATA S7AiX6ZZ8maNN9jy/Uq9Frv+BB90JqVbznKxd2YnX4bCSozme9dIT7//IDMlJl0tp6/Jv7cAjj4OJsMo2HaOKFi2agVrZOQjtAyR
# DATA UmOpP/fIET8vqJChQt4cqloEl8BNM7DclOomlzfTfEyUzEpnt2wUavBEFWbhy0BWzZQxLG7he5q7b7KLZX0XVjarXK3JSYZcEYBO
# DATA EDiPhfL4OczxPmX43X9790uu7a0Kef8D/Pnt+5+//+t3/yyUufnuN+/+Hq+wf/dPWAhcV/IQ+DProF/uCmq5/NM+U2eeyfnUR5SZ
# DATA v3twBlRrXGZApcexAPlvHpgBJU6Tbv02OC9RWvfFth8QkQZIoEwaPCf+bC4SCmQp6ApOvkloOcMFBtXGXNVniXDJiZ5aiFtND5ol
# DATA 6KBEmjlnfLj3lOMo/DO5UgR3jq+XA7YEmz4NThfKJFM7Czqd2y3xRodkYTWUHx48C/ju/1B45XruhPXfvP8bIims5A6fsPz7+7+h
# DATA mvDv/ws8/kcqP//P8NK/8JHBggL6QiwWiHQMAe0YYG7qTlkmoGASddtIOMF8Ah/uHoT5v2Hh+d8gkb/7e6AahOU3XBYfy9IDpViF
# DATA 6bHe/bt/hqn8HL7/7Vp4iWQAwqqJXhDs5zm4L4ozwuS6s5EVpHqrR7nbfAub+G4TrKnlm8232OFdDTh37fJnpVw61kw5YEb3BMSs
# DATA nrffMpS68N+FGoyHKa3YYMbhTBfn0RKok0nWQzaFnPO9j8mytLkRLAQsw6/e/cv7vyvYxb9Y9VTfc+f6I9HxxxJxK/HV7PkT8WZ6
# DATA +sJNdr986NSY0f7i3T/Cl1++/2sf/+AHIDOY3b086/HHXlyITRUAvC2tuAKAijeu7YQ+qmjbB88attTf+bTXfk0T5dsh+GeY+8/f
# DATA /Qv83y8esdbEiulyF+LfBBunZCpZY+xhTPWk/VAQkX3LPP18w8R5YAM8EfH5/7H3rt1tpOeBoD/zV5Tk3RSgBsCrpG5QkMOW2G6O
# DATA JUpDUna3KQanCBTJskAAQQG8NM1znDjZTE68k2R2P8zuObOzObtf9xyn404c222fM79A/Rfml+xze6/1FgBK6vbsjjuxiKp675fn
# DATA fskXu4PzPkL0RboSi4XLQNV5ZQ5Hg3Ng6NqqSnsy6gk45SG8p2+JVYupEy6nVh8BDK1zmUP2fICYMOIvBBD/5PU/w++/f/1lBCv8
# DATA BaUf+QVlAcGT+JvXv4y+m40/nhz6DtzlUlZrDuzjShG5qnYEByqyz58pgoMKpnbnzuob3Rc5DDiBn0w5JEICKoJEuavAnnbGRbLP
# DATA SeiDIK/a9Cm+KTTjgpXfShu1TsFHgVn+Z0KIv5BN4pwqkgMlgo3iOwJ3JqJWAR5G3KrrSqGGu2+TXgeWps6IM5UTdgEz7eOzpMCV
# DATA C4YJ3yoFemhf0UIHNHdFOSFxIgeXUMOBsx9Xd+7QR8crRgaiqRLKwEqEh/6mCBHPH8YeOxRm1BvjpWuqkxe8ktgFHcmme0BVYAvS
# DATA x0l2qAr/EQgoB6NHSlXOrQgfFfk0XfeqXRetOs4MOAoDL57z4UDyg+pqg1zABVED8dSz9XdFEgbgq31nHFjBtBkURyoOzyOn/Pmp
# DATA FZuMZjVDkexQnTInh+6cqxWUGhaaKVKlgVn/Bxr1n8FE/hbJB6DviqQnvPocwMpPCQ/90lsSJF+h1ld/ZV1FfOmwRgRvdNjF7Oiy
# DATA LX6yEmjMPjNZgLW2ZjVPFJPdjzfqUCgE9yzC+3PYSQbtAOTjMsdlHmA8agL9+I7d7En3QjGIJqeVU/Z115lZrXLvl+GC8lP8+vPg
# DATA 5GHeuFf/juiK30SYaQtBJrz47et/tegGhFG5o6Wd06FfSHNHplKxPOOLqBINzbO8nRzmg95kLMbocaNBJlj0FQNd5iW+/AqHVnQI
# DATA AXILsOIEqKAC8xNgwNAQEQmnA9ZLyM/f0fH/WRRc2C/i4LzUDPK5ukbc9jkiMcw/BlfprzEDGl+nG3VOPaLE3fNxR+0im4CEQhPE
# DATA Wibh5WkVckbVHoyKp7xQWYVtCFpRlK88AA2noRnErSrrKMMrMtDivVOli3KgHIMw+iZpUGhfQA6zZwcHN7h8BGA0nYLQ8BeIHF7/
# DATA E140C4JqmPslcjR0LRUJU8rQMIIj6FgWZ8KamEmnXdhTu6Hgvpa08+bbK/zMX8Cs/4kR7Ff/E/z+5YydNiGdrCHbUTSU4abFFXji
# DATA V+UiZos5LayieLXZe/wfcVuRJ4Nt/QuWzPClfQNsQ3OzaShL7mlclBk5uuhTNOIV+YvaahuHfjt61AOKLesYFS5KsHMyNeS+BMmu
# DATA G1OOrlNK0/QiHmZSt9cbnLMM0F+4mlpKze0faLtXMY9dPrh2LBHU2M2N1K/owJGthTAK0vMcxliUlfGf6Lb9C96usqunCDW042g5
# DATA PS8U9uXKJ6HZGGTDIT6BShjk+tuzXCh0ujTqrbpD1+FtzZOztFth4b67o7dv336EI6K9gXs+SXoE6bvCp4iVfF/pNsYnCUosxLuN
# DATA DTwNdEXliYsTdPApyfVq4hEVaQG6/srEojzUi5qGRCn68ZRYL4aqKHz+A1Whjb9w2d9r2aGRplIdKkoXPZCViiE4GYC//5ZCBpOP
# DATA 1L51/0y5UFEiCVduDgFVGcFykwBRpaio1LoF1UTWjqOuwKViiu2Y22LIjSlhnvzE8W6PJu53LFRTJL7SfDT3myskJKjEh73BISdC
# DATA YNanxH6HEeScYae8lbgp4mzNQpwurVIIjiWNLoQJTDy0iozTqEFe3JhU+72QaT7Bwvy7PwVBBkZvqX3k2Sh76iTK6ZCbXMUZBMoN
# DATA iJNvNoM3Ww45XrRK8kg3hQSYLFXkiG2OFWFMePZduteOk+PpFk9aITpfe0bGHv8+cpG74rZpJZUV33zTIlHnvIWVZeubpkFXDr9c
# DATA n6XNgUNiSZx5k1z7A26CVdtBq2ol5rW2jOP/oeuwflfIxy6jwquiB9UMB0fxU6gXhOrhZOxsjmhFJBKx/pTm/Bzt8mwfB2VO7Pan
# DATA hOX+winxZGDdQkar/sqo21tELp4YkSri6dIQqYB7/bYZBpS2LKQ4m3hm/cbhBKO2lDSfp6XtKE7NXxnNwqqFKTQdymevQtjU7ICG
# DATA bNtaElBE0Cv1STeqOFI+KBgViepXZ9geMzLavcyBo9m8AP5u+Q0tJp1sRr8P+7/lpeV79+56/t9La1D8D/Z/34z9394o6ed8KYGh
# DATA 5RxYgMjQeykXDw2UJqQj4GCNszfAKaScB5Mxl6W4IlAELd6TXj5/6rfOYHj59kndsmMYvH4aJ+P5PclVqrdRD0lujjzjvkMjbNTM
# DATA 0njkHc0oMuVIzFLDX5M+/XZTyOFF5rwsfUCUY3QLw8tOXHSbZGlAa5loMBI2BkC1miqnbLNm5WU7Q9BDP/TcerKA4dxtkV7+U4AB
# DATA ytMCsDfuDtCSHRReRU81eGCa18BBIxPZiLpZctwfAGHdYZkH0M4UdmY8iPKTwbk+KATk6KAQNTuRkbD7G50Y0X1DZdY80adaNBjy
# DATA 6XQ8KiWAIy0h5/iyeRmVBMcVP3CdljH/bHCmIf1xapQ5fzXmkSqgtcififXIv6Iiz011ombG2RBmJu8pjuD/BmbhX1HCVuiIVIBo
# DATA puKatQXT+qh0QircEQ2nUhyPXia8YhRRsl2QY6y83ain6seMfhTNKlie/aVvdgHs2OvfucYVOGYdKhY4sHE7oQAWttWwXAidl88+
# DATA ZCZ5XxsPZ8WYD9ci45khcY6tBWLTDKhMIc2TcWO3vfX02ePNCkc6Hrfxm7GZxYJ/FC0NAC2Wh6ZHozapDaAFOe8B8bYpPM1zYv53
# DATA 4lJ/DusILCnznb8iG5vfogzpd6hfxm0BNvTXsLIFnvw3X/2U9e/Iff8L2yGSwv7XX/372A0E2Za1FlZVVtsxsojxVdw05xHDgbIn
# DATA SzPi8M8xyVXlMfoxLs/yMiVoPANeC8W6shrwglhMDmmh3sKznwQkPK6mkaXCguYduAKZDIrouv4Y/ea9ANkTlKlYprIpvCFpb0XK
# DATA h0NhS1YBPCNHAxSrK6CTC4gr0I/UkStAlPO0+2T7e+550rJTXWRn87vFIvrr462dKV93nz3y2i+VuM4PIPHYEVT6OR66X9lHknXk
# DATA 1qEMGxJOGR9DL/sV36r791nBUXp5bjCxf4DzzsKdf6QpfRF99RcM1NAkd/qE4DqR9fc/i/2uWgisBJCO9M0oQPoVWvDCKzZ5q1gd
# DATA 3FsCAsLr5ZcR5u/QRh7JcNi7bLvQjv+gVxkx8g46VUwKFWmW5A0hOmKAMqRBzpoGLr/P9/ighu+ftXceP9t+8incVXqC47X5aO/Z
# DATA jn6x/eyjZ0+ePPuBBFO1mVC5H1DsiG6H6dPRMlacO29ddZJE6kEJiDioReoNQ4cD54QXAbLSeOmGBCRZDTFQCqeZuinM/SVbCZKp
# DATA z6/F3ABPBQJgsXVC0MvFLRrCMaulHQ1LLwrwLrSquOQcm898NdNVC8DxJ6gvtuj312MhGFcRGu/0gLp0ehYfHs1SiL2iJflAgrad
# DATA de0g7gXvgqJczTpNrFjkdMAsekm70o207ayk8VXHPpI+mXN5OywRQCQ8s9K0LpK8j7UINUWts3piWtEqp1Qy3hRuUHJdpTDJHMNB
# DATA V2QOGIA2YDPiUHTBWbBhlTNaQcLeqGDAoWFZM1koNA2fCm3DO7txZzPVnfNEp3NQNP8BIOQ/EgVIpoOqb6yuCMbiKana9J3hOPw5
# DATA 0jqbQZqVFj0setPg0hTWULsQYQk+VJO+ivXajTUESj0PJFam6Md56DkgyghKfMnaiAgQE+oQfs0G1EZtQliFTPf/iQwMyZaQSG/y
# DATA JSmSzDUeYQ2NYeVXjFGame6iN/sxygt25aU2S5WYy+0TYAsVF6e9gRFUuFjHstSWwrD21QINTN/oJfDZGLVD+G6uRFq05iLnoOE3
# DATA 7HSkLOmR8XE5RWiggUMk/SMsOw9xSr9SZwKroLTU+DwEZvl8MOrqZ+AkZu/c3xl/ij+zhSeuqosQx5e4o0AO/DlbwDOC+AlhhN9E
# DATA tJFAiIjfEpLqX/0VqZz+tZwB1YHMjMiiUsGxk6+e2qaaTA/PAv7600mKkV7x59EoOT41aVSc0EhlWyHRllQsNiggVikq0g05SLbT
# DATA /lkFRbKSvNsOr/MqvZS3uumQV1oyhsGjZ9oo/pPKd5rpBe7IfvRyfPBe9Tt4DoyrDbQo3jP4+U6rced/iG0wiumyUxRyV6RVjnGE
# DATA VFTjqQdX8QMHxcMkAbo8u4xG7SYOH2FISx9F1dhRLznOW9TkFH2CtI9/VCZklQiZsqu8V+xAPjmhdqG6LPhwNLi4ZPE3j8O5pLXo
# DATA VdbvtuJO0u1exkbuote28p0Ht6y0oo36QdVdXG6O17fynUJZ0XCirBEtmogeFVpTw5CKn8C9P+j3BhS+misuuLG8kIKY9M029EP7
# DATA INOTLdCLv2UbhalRqV9k2I4tP7QSDrkRweTI4Kqx6+Nx1nds3tWlkxOCi3Ja/ZPKy/wORb8fkfr2Zf5etbL/J+twVivr1UJYSssa
# DATA gucjyQzpD9wl2gBeOn61QnH9+PfqAZ+4kAYJSDHChkuWwWrfDifj5zanc2jFucEQD2hTwdEqikEJWR/Pme4YBHzbidpo3ToZCwyG
# DATA uLn4KmZPVG4EX8lv1dKVaqmYDcd1rsLoJEfsZGWPhOsHDE76hN9lQbkJum9XJEejplxfbxr5e9rCokGHBjuoRnX/5bXH3NI6qmh0
# DATA lK29eHbs7IK5I02Ukzob8/wDIhXkLhFD/IIIiC+QViAi4UtiM3/Bbz5HauJ3ZKvwOVAUfwtvf0NIZ5Sij0TKEGTdZmKIkUEmhl01
# DATA SKCkv3z1N3F5KD2dbhPDAdUiSyxToNMYJWnBsBHCIQBsGXmSvpLwWihMbFznFiqkLC/k9ykKRwmVaXkcDc9uch/6OqAIrVqSVcgs
# DATA RrnAVZp56oK6LySgwl/l9198i05Z4uUJZrXc4/79++UdUCD2a3tHYPQqs2Y3Ux4gej8EejTttQ7s2kJ4VTSfKEhMddQ/o6BpqB8n
# DATA QrJmsnGYRHgTsYGkEkw1Y0Vx66XgpNNoymKANd3mPv9yQsfum7NG0l4zIOQIqIKSenhB0QSpcFQ0WmTGYBye1KNdFOWjVCJE/GSj
# DATA QZ84Yl5R4BvGnI07D1BEJW4Osk5I4EF1vfD7ioDHLSFbMEv2ooCdMDNKJWSPyF9+9SG2zApoK0nKWdhWHgvSazgUk5XnwHVxmY/K
# DATA s642Bufg4Yvsk/oNZG2gQuqGGrreY5sDNb8d7Z2kgHHzcaROHd6mZDI+GYwyuHXZWSqOh/30HAe1LuQsZxNivdcQA9eOB4Nizo0j
# DATA pZ7K+mVDIEnKKDumOLUt93rRhlhSdO3Yx/tes+CabwUSmD8iXhrEfn35gAPLKiK4jKBmwlNT0dCjGmqQUnaMN4JwxuIFTEtX0E2T
# DATA 9+3aDatotr/8iNrgz4tQy3X2nfIHZJSOzapLijoBGhUCdIl+qF+6edCt2KmxXCQOEQgI80dw6uvkhGokJPKaCEAJdCiv4HJ4zqSm
# DATA EXODamLebt0p7O4orkmyLTVKBXHQ1guvoyw6T4Z4epkIzjFqOYphGljVMlJ37Y1EmVzBomquYm8W34mNKb4KlZgBLTQaDnpiDUbv
# DATA YAPqpAefiHmhE1bUlr0oq/hAzMZ9SRCuxBK16I4la0HReNYh5bPER3G/k+HurgKTVODA65NAZxH82gbgPFcb3h5okRHF8tPm/VOg
# DATA uApMp4SYypQJvZNpwyx5DFa1wgmofvaVxe/hYNCr2JHu5DdPenfMu6ABhyTcUquNR4WIGgLezUh1T9WaZMYB9Ew6xB8VPka2Lk+5
# DATA JmttnluBP/vnfCRDaOrJmAnnMuP82qI1cJAIDIWAxkcTaVRBVz4bcqw/8slAj5oh3F+4WUgDGDpn7ioCEurSd+PytBcXx1eZ0gCl
# DATA fWyML/AysBKa5k2Gsn6JaiHn7BQLh8A8CtpaXE4tN0jRRKUoslfSNFd4X0NzlPZpCrhSvUBtOtGo9jMiFXnO+hTi1LySwWpxnaFT
# DATA 2Gapor6Y7Hu6T4fuJe2gEene0iGKMHGTqaLl0Sg+RNij0DgBst5g0j3qJRRxMT7u4CGvzmkw8gsO5UOSPYwWo0NA/ZYUQ/8Y7T3Z
# DATA Ra7s18xDoae7YZqgp64Wy4p+Yw4VihFHq2Wfe0lMDb0iGKc+H6cJSemR6u0mPaj5divwE7Y2QHnmnyEHiiyqP39lSqGH5ArRccy7
# DATA 8O2psrnW46yGlUc8SZz9nBOcb37IC38ustsvp83u86J89udf/aU/a5Jf00WwDj0+VvSl0VvLDz6XF1ij55xdam1tVQD8xSi5DHZi
# DATA 30SmtOznGV1tcWHp7X3T3ay9IN2eWXn6gF4pV+4CsA4iGWbUA2Jys1o1M6dr0qqszt6+/8xy9a/+Jtp4vlVzNgtjMEhQhp9Hn0DL
# DATA BT2+CcMgenzZwPwkGbEocYbqUiwXQmpIPOoVB7kHNEfYKqvPqCWrlJUAlVyHfOzil1e0p1XakKMGmtDECgpXQ52YCTTJUIqR9aCH
# DATA i1HR6htHQ2Nmz3BdgjcZPc0cKmBtThdcygXPcNzokawFsBt9MaKY3/sxzH1/6eBmYyn0Zq8y7tVjnmaxLdlJVmLh9ZCSVdeEEBaT
# DATA 5aFzrMm0CVrAjTfIXZb9Yo0DZzGmD0rjlNl38D+a4CdhCeVUNWYjev0PBFX/igwufo66si+oOHuOsY5YqdgweN6XVJXfC1b6ubz8
# DATA lY4mw0vikRzwkoR3+JG3KVarYOiUll4NlyDRmNfBySGvs+IS/T/kaPbn9tKwORKFjjH2eawStEDRYdJ5NRlaynx+wfYEcuPqTszA
# DATA Geltub5kUVaJktE8yc6obOSBxEIQucpGfxSzVLHIBMWaNvkSw9LBG/gXLf74+DcNkVmSc/yasmchqaQfmTNoAi8HD8MTjDbahB9M
# DATA xlKAOJ6IDIsfqtezUFWQnLIzGHAs8bbBzT4Gn46ZPQsCh8CpFnAkS3SNogwYWadni5BQ5qYzmsiOQnO41fLa9ryeiCfBjx8Bgjmn
# DATA NJquPLzYpsUZuk3zFqRHR4B6UMTWEpsLZ1NuhSGe5Igo4lKa5ZUetIOu1CmMgznebGsHFVHAEjO4sgU4bl4JKyyYJ2aAsqJnJXny
# DATA NCbwERZjsbenlNiX8A7CrAdFPHopqxIsWRpXtvTFPlW2lAssQ2ewzorN6bFeeTazbhC3K5R3qajaHDAdTqEWta3LdDRK85OK8rbU
# DATA o6/5tEttijjc3yvty8y2RG2GPy2Xz1TLHW6SZoeHXw878NkKp0PRdOcfoamJ6kSOa5z1G3k6ljD+lVgSQLAYy434QMpsDLtAlZvh
# DATA tOf0kW8Qv4urnr6DSjj6Dq6jM+6hgQdbhMS6OwddFvJO0xlZPEtGi73s0IQ+XQQEGs9vo/t/aUZKI0eOWfozNsH8R/aL0A7a2tjy
# DATA V2jMDvQDm2R+gQw5UBX/yebUmIj4gpy6bfrkc2V9A//+eztSEq2xEkxdxeh/i0DmMKOsC7FkM2PsY+4k3PZOOsLse1BG1r9ZujSE
# DATA 9pJuG1N+K4LbiiiGUtRe9lnabevjsi+HYPqGTldAepNh1EIHwEpevaigrhxIZ86F87J0YE83cJyupw8pcLynzRFDkFhn88BKRYyG
# DATA s9ZCOQ0XF1RP3b0vJacZYJcbChv5W+nSRF2QFzpkAS22MVHWJ0jWVVv/+/VUvjxiJM3HfW6QAl3IBirmidCBXVKaAJrf8aya0wj6
# DATA P/nGBeQE8JdkW/Al2ioqcv9XU62l5Uqvs2nBbyXo48+YemeDuJK1dnJiXVyaWzALfu9rKHoQbGJ/hSNqOCJwvW5V7zi1lTFDYGWd
# DATA eOLhPZJ99qxrSvQEpK+xYnoaTEO5oPTB3o93ZQTuEXdUBE9psiaivHXUH6coGuW86lPPuwh4dEXptlowAOKAcTRKvgs3cjrRNrDk
# DATA XfEz56wgp4coQIwnw8fLD/zj7JyMyzZbghFb10VSwGniDJa0+LVcEC8ENBXeIAN7IqBdZw67LZ8S6XbT7nM8oFQP8YBXgtU2cLBc
# DATA IhRL789QhdUii2rJjm5MwJXs2o5tTyQxUTzLIxVl+H9msbHHq1O0RnIaLEoAvpwHdf9Swsi68VxYrvcLcnDD4N+/NbLkwMxDE/a/
# DATA KCKAqjs6bCwpKkqzg97Z4NaUZsyiML0P1E6BP/G8y4oWpjdROFLXXgDz0uG9vfaRqHg50vTL8CXqYtqEU4WtLxuoWpzBqVgM1Sx2
# DATA pRLeI1dRYskCikq4kgZImmDM2/SsnPQqCAgVx0OzU4GBSEAyXZbwBqIEbwKzvBAKUSXhsm7jKH3rwJ97dPI63jzxgJLb+dXfaxt3
# DATA lK07xbXw7nOC7ra8TgnxfJNFyRRDcsNfEr1hB4BUZtuhlTUKzXmlJ7RqAfNa6cUyuZ653zWWfJkxxPMz3jIE37ZGd2TbAbOtTbdI
# DATA xJAeP3wnJP28AXPcxr4j1Ma76siHHbu7q/ijnWfbe+3N7cftx8+ebmxtIxdhKwOsmT/f2N58YoqpL4auQXE1J8u2fE/gpbeIbIaH
# DATA DiSY8XS6wP+g6mB47MGDxmrSRdm4CNB9uoZGeas1ryTeXTMg01582H7+4sMnW4/UUqiOyPS56FjhhoGbZmC432dLFL0u+640i3j4
# DATA PsnaiKY7T87SeiCslbZRXNCBfwJnNXBwLBVH8NxIQZVGy4ZgLfYVt8Fey1YEeqrIllYMVovDKJJEDs1UShjdGJOrDgfn/bTrdBgy
# DATA abLJMrdGLbxd1ZojrDuoWhsyw9Pxja9S6CIcLLzBbfkmj+tV4FY1p9ypa3er5VQWrvJTFWuldOPDpdEwtuQW0N6xZsPEzLS8MJsL
# DATA b9/H7I36OiCsiyp1/2WDFLMn0fEc7JMqiZ6qdJS4fsg6S0otFHghBVbYxFSNgCyFxSTZck99rFXTFtDyovwxKLcslKXNa52jD85f
# DATA t23BRq3yLbuhjOB1DW6HFYqtyNYlsTRQU9NcBgdIxkzTyYdkMh7Evnnw26tb7HZLjbPslA4yLVNQx0nxDLSoYTW3eQy1SARWan0i
# DATA HbfUiN/Y5qdg0/W5mzjri/WSaOzaecYjm2OjR1Wnlei5Fv1rqT1ajhQZEIGY3vEfogJRHdLylSPFqLbpCDNYA0yVQ96qOPDOvgzV
# DATA GcdWg4ep3exa5ypvxTVxdiqFsgaQVCXvpH+rSm1i7Gaec/o30UoURwin8JFqslXohOwbiYdtyUA9ExnqevocbPdVgm5li0LQ0F+Y
# DATA EKiueg2qMbI29s4dqeqBLVoJ21rHNk+uxJh/rXOCWqZhilnD4fRkZwDg6LFaakcbUGnAL8dcc26jHt/qiC0N2mXBE0JRCrhK0XFf
# DATA NyRuX/p5mveXLskKzcSINUrIASlH8hVy+h5fSt+l+LrKLhlkzOlJbNjpr62n5LJwEkluSpU3pBFmNfRm5ELZ6oU4sjJCwN7GA+PA
# DATA K6OcbvJsavqM2xxzvdWaY/wBv1Tu1RjP8QtX1ia9etEWAu6qr4iP91T/VhfqoboQjhQeprm5YZfqVmN6M7J7hlej0S6GiPPZmzGV
# DATA dP929IQ8yDl04iSX9NYcOSTOo+HkEGYUvdh5EnF8Ls7aIY7gHA8FVniU5nljPukIG/hjOrlR2uNsEH0BAXJ42RSq1MtNqs0IT1Ma
# DATA a79MrivNetF0+90h4BYbPtonQrVFaiUlr918ur3xg43vb7ZZTgNLx4abIfkHbYvqpOpE4ADIMOeMyo66zIiClujfN7bskZrTjXuK
# DATA hQ48cfhcVyrQDDKloSVtupFV1Br6ENXPKop4g4/ZDaMLhUILaZSnGy2JMhQEsLpSEf6EYbmpcFDE115rhEjQ9km7eYtHkBnYtyOd
# DATA 8F77xOUUzOAkzUbGv1KIYnbYvxhLYAzA3JcCB4wLp24H1RxsX4nqB/26riNuOk5KlA2WfZSqoXVWUz0fZZg0XrXmWTDZKZrY+87z
# DATA UrRdbm1vxZkOehz8XRxPnLHoScbEikjUK/zt+AuFiun4QBxKXmLzprmcD7X8Tmi6OXZVcKc9V7LLVbvJZt5aKMd5GeHObY2JiLXr
# DATA VX0X6rC/n6/VU+od7azKJH+5skfLbywZXdWNsyFqNCK8aUEk2mgxNU94jHoCIpH01YMsWeelRi5cvh6EctrkIbAsB67gIYoGt0Pt
# DATA u9lJ63BJR6nt5tlNh7l+OJxkva54xwJ7QWIVVAdPCX1yp7If17sSkE6WiU0guUmyPSIZ6B1OvuPG7fQWqIBty1YrSL0xEk+6l9Pc
# DATA MlVaXzFtPRLL2AoJoZvFSIgmcHUDhlHZxwjS6UXamYyTwx55127FwSDSaG/FXsR0snRPjSGcvCqlk1X7QBLy+pB1hASgcDAIJTDp
# DATA CFlu1yhI9mAybq0uLYkAmYPiWwPc1T833ej3N7HQsHX0bKGBynl69dPXv4te/yr6eG/v+W5dueR89dOgCZCaLvnrcPARjlArxkX/
# DATA TGIWNEP6NVxEipBNzJzAJaD2EGzZIWHFbL08xBvDJDYqP2AuGa9EL+V1xjbTbh2bZX5ZbM6rwSib0p7KVW1sqDeQ+HCrBU5TwPTa
# DATA RG+cG0nOqcGwEZ/ljSqW9GSs/PZo8M1Q2+iUjzigGRsQxa5OxIYKvS4lx6F5+JjiQ54ReyI5gUil3qJ28qcEK3mDl1wl4wwE9Lax
# DATA qsKG0oQ0WnWkL1Y8DDfwQ4Fh0Ka7Rr3MDQSi5cg0JJyJifKZB2IkcLuNSZ9Mlk6zHNmm9uCV11zRpsQlHriZmhUTR8LgeIMw4XFq
# DATA anynHLyVM88E4ttaF8e2naqaiLdmqDMpENdvxdzvlnujA+QRa9eZHBKwD6ewTULa+QFLoVeaMaKjGV1aDgDOTVPmaiXoTfpjE5uq
# DATA FrbNggNBIsChp8iFlm6h24UdqFgmYIk8xQ38VXppe3/fEBabmKKWo49exzkk+/+HOI8psbyyI/8XMi5BrPPvHNH8139bDSNfCCol
# DATA F9QOXuXGmJIC00WZqoNbLR8szGvmW0hE4AQ4Jp+9n80KcdyI7GzMyq5HrIQwBL023HPUIm98YRza6yawxQ25S0MQbRvJA1mH5AFS
# DATA P+2SKBgaKLBtD5NMociC9oXQnHlZ40BJXNgJ/DJLg+DJe5iiM9k9ShIZlW+7yVwkNBXnUfFt8sV1qx/t+xoJoNM99r/BViSVaiCv
# DATA oej7xyJhvlJL3vR2oBbZayDeFYThrdfVhmXKDjVgTe2SGB/ULnFd4CTmv+wq1yPz7jq2VWCVncNqdaL5/iBSVKMimqqmqTyTlcBB
# DATA CNUStkfFaLulGOowACiSTUHyT8giRfzR0ALRp7ilgh9pdcbSGPqLFXs23VVzFfw3bert2tDUqNtOQWrjGs465OaBBDK0ycHyrn2I
# DATA FirJzXt0ZmHGUybBn5AO5v8BXqXApe1R2ksB8HrIKjQ5JXVRSkiHhnfD8jRdRB8cbtUP5XMdDK0m0k99RYtgplkWEE1knKEwCqXh
# DATA 7Ih8sis68RTcalr9Xh4hjVvyZ6oFXt7C+uWCzXImKBKg2+Ms0ViWrY1uhSwn5OENlsqt+naLpdp6Z8s1+55NI7fLQqnNKY0M0Bfa
# DATA DL6lbH2bQW5ZwrCh2w1xwIondsRvlIqGlAgk/6Xm7B92uk5Mdqrkw4vpuLNIpRaN+TyVSbrJcCyB7zzD+jB/OKe0oTRJkyMM1Zma
# DATA JNY+PVQs9GR7NmvaSair6rtaRxYvuMIGLDaOnYC+AQ60sN9FSVBcneVvr2RFBe+f+dHGvLKlAkIzVJGm9nyQG6SLQiSPZX8+p+Sq
# DATA 0FK7l1wOJuTA4mDyIq6Z80IW8E0pag8yJLgtC/NthZDlH0L9TfoJoNhiWR1RpcvJ6twqGpbPlVzlLcOL6aReZcE8zNVrBqNVehsS
# DATA CtTnhfzQIUEKUYOqc5kUvZuAPCQX9EYGvMlTxZTMY5jJtoY1iWLyNBnaPMisYIBVneKMM96SYJ/BSXMeeZCwi3rbDjybyJC8yJGj
# DATA NotHOgFCk6CxGYzN8FWnCL8NirulUZxyaw4OxUlQ4LWpsteE58hbauUUcdxPXOwALyrxYjLMFjHq7yLHpIxZF4598LlYVAGDhhjy
# DATA ge3arSyiDVJ2tflrxftGeO9jWPEefLtSEW67adKV0My0tKcDWIhBP+tUUGC+vMLhWs5PMCRxocADXb1ZnveZs97RkDitF1lpKc3P
# DATA XUqAB+gKVi6UZtlybPN3xiXetH1DCbFt7VrB2AAWOFzpcNC9dMPQqpGSJKyCWSklOSWuVnngYy9oOLZrBQgIfOWzp3rDyzut9L4p
# DATA Kac2y58M4PpsoIERKnZq5CQ5JVAyy16MmIakbSgkI83Wz3U6GTYeVkkxf4qJNn/LkS7Qn/V35C33BUriAoS9tweCg+zsuA3Uw00T
# DATA E3GobI6OAKTvKC2mXyLTKkCMUCrCZDpxHr14sfW44dOFkoOU7K0ADnH/HXG9W1taq04DC/MfvvCkK892JdO3nf/bWQqYhp0O1+iE
# DATA c+PKQlcy76XpsLIiiDIsOiX9ZiSejL/1/JPZjVkJS2U3f/L6n+H337/+UlShGGOSQ5aE8sEW3SV/rVMyqCj0rLZ8C/XnLYvOmS1f
# DATA /1+N+/UXX/01On36SSNwdnFARlvEdOV0l9bGfmOEV5YPMUYA5Zk3qa4oAzzAV0l83FIy6tgTPXN6etZH0U9H5ktvUCppXIICDatR
# DATA xoGB6+anN6GXzdH28AGZswlU/NQZmVtqa6MNs5rhlaOwejrpxygnDKoyiDc2RscTPD7P6UvFom9b7XZ30Gm3q1bNBloGJlKlEuuR
# DATA xWjgMEC7j9a+0gxpxZCK125r75Xq3poNZZo9GujoWKEOgVPEQHeASC+Haes5J9sDTA9kXNdWL4brGkrFGa6THK8WImqnDwkosLqm
# DATA Ok278/rOTG8cmcP6KY/MtF0WTXeOtsg2pbpeVkZC0UqxgLcCLkg9IwLbRBPF8xZ7qgGR+zs5xIJdIllo3Bbw/JJNLZWlP1g6r1Sn
# DATA 3Hl15Ow4gRmahUpQbarCrBbffsNC0TPPRB6EA5Mn4ywlL3RQAvuZfWLp2Q7mWy2/y+xnpe6HfSfsu2LdDzvuActsjjr9cc+B0Y7S
# DATA 0wMopQlnSSRCNk6ce6kSA0qCoVQl9+yjnc2NPZVpdufxD3b8rLM1znljulEpn4+61IGd/jQ+j4n2xR5cDE+zaRzhhwr+U5M3T549
# DATA +l578xOXrnLRQcDfkfefSNju5HSY25Bt5nFQPDimoc7R1DjJO1nWEoNB1Lf0x62VKkJY2Ng22Ya123QS2208Se12bAwt8+y4Pzml
# DATA DcefSa+xu/Xdvc2dp7XIPH/84rlthsTv+U+FG9DJ1u60gY8l27VsXFHUt4PJGeTbiLdi01uaCPteesm0VoDsZPpi9xLAzOnmRTa2
# DATA FJJe4K+UG6soCuCRWGjTOZeePDqlqvzCXv+DocU0ta0Js4JNQNA+bYZNGoWh+QllzEby7nMV8eJXlED7lxRT7lvv7r/TZPTZIVyo
# DATA 4eW3vrb/MGH5vbU1+gv/eX9XV9fu31Pv5P39+/fufSta+tY38N8EDUWhy2/99/nft28tTvLR4mHWX0z7Z9HwElBHf3Xh9u3bO8A7
# DATA w0Wg4wHc2cbzLY7aQ2a8xLPl0fhkNJgcn4RcZ6B8A1pZEOCvKDj1jBoFvH54lbtj9RaYNuKc5BEI+BNgtdQjgkf1e5AvkJkBkuBQ
# DATA ROEYpLFUkZHuDMCP+ol9qt82I+e9c8bqymj020nW5TEIJFFjIJYCwB/wSQBxOz2YUKQ1acz3aKZCE7owaeHAdBpYEYEDOj0dYmKN
# DATA rAsf7MyKbHRAmFGcS4yZ8oJt2Dc9ny15VAKAzsfdrN/I8mQ8vqwUTaPcGcRP2fwvstxaoNlRhsbJTIMN+pTeJ+GwvaeqfjNyKSgZ
# DATA kmx9Q/5WeNoEvHnmDIKz/nAyVh/18m4PdlIWjvoCNWSp1TeRq8nU2AuBv7SleAUpVaLRAZ0PUdCNdNNpfgzLD9cBjnwNk3tBHzPX
# DATA BzvW7cOPH1Hu8XW8OHRdjtjJhCQb6NhjJrMxzMwI2+2sn43bbRkZi+UGr+AgxE68DiNmZEZJe1nhWB2zXsnvq0zjrljeqd3nr7VA
# DATA xbhlodbFTXnsJjzmrMD8U2UFDtqKeWv0AvPHmzUgQmwwGdupkGuRblu1HIfn02qp4AYksDaj1xNdXrnfWIL/W8bJUgZZLIMPzeZy
# DATA fD3PiHfS08FYYF2ueDm2S+etTSJOTbu7+3E0nvRxZngZsERsO5b0jhq0l/SLNpR3UGf1XUSClj64teQcktHTJ/WPBqPzZNRNu/Xn
# DATA owHamUVmO+2v8Au/mRW45rUzeQzmWCCJmn3tDmguMbd1QZEONffPvnY6OAExyigyFRtQTP+lyFkxO3b8gyhHirUuaJo3JEc/y2Fv
# DATA USxY7tyx1/HaCbipN8M9C1J2P97gZH+fiX80ipY+TIFjGxFMM9X9nKK+iSWJrEtz0Umlin+hxcoTKxNcxGXhPbEYB/pabUjZange
# DATA jzgJbX1Pooq6C3VRPz8/p5xrdd0rh/U1PRZX1lHSYsJlgNB4rEboK1dZteJ24E397uae6NGWq3MYR8JBKZ6wHev04PqgvoaODi5g
# DATA C//RYLulwbcTCKMo/SZe0DrXzHMSQlDakLVZ6hA327GrjFhdUaoISyNRppDAEKjSUDV6GPl1Z+kJfOCFJJwaDeagBA5tdJyW2PYI
# DATA WnaS+/FIQpajN1IPaNMhpiCCcv1p+iH3OtkteufLaxlh3NrKB7Xo7tIK/rOK/6xdUzF1YB9EK+GubSE+wBBVoVq6+wV/5VkbQ4c5
# DATA OkqyXtptEsaIlM2kmUTVdlkKbEQlqJ2oRXt8eEO6iimL93tfFajSx2QFg74szDoqjFBVfgpFO9HzZ7t7eCrIyMz35cLBAXd3OnQy
# DATA yAdz9VbIh/oIDvrYyWGmUm53xw3FsVBENq/pGhbAd59B743JuBOS8ZQ2luUDTnDJjTVUrvH4h4h631taai4teXbm3FZj/BnKoMPe
# DATA OlaqeSqrWuU6reCAnZzcjSRXJSp+6YYZc9WMV4YKg/6hpVHqn6UjoENzNBvN/3SSdJGmG4wTTv6HQSKSrM8SZ21Nipyfg+Il4x+2
# DATA wrpTRY5aQQaElxnBqk56PYrRXBnF+xv1Hyb1z5bqH7TrB1ertdV71zEnU55Jw79QJG93kDKyPsrGRL13TbjriNfBO5ijFCqSj4mV
# DATA 87N9mgyJQGGeCAmUjUd7W9/fJPE0cF7AO6G5SPx4a3fjwyebj4kOy06Bn6TXT7aebu3x2/RiiFoEfLv5yfOtHX476LdPOGGOaUKn
# DATA sDFrJ4YLOoa8Gd3MFem/6g/O+0ouEKmWFjggwynG5YN+upQ4lzddjHIAG7epAEffWqrWvBJYrT0eJUdHWUeVsbd1KXrQ4i7wxwdL
# DATA S/eXP/hg5e7a/bWlDz5YVlwLlaIRBArNmt1Wn4wdIxkFnN0JcrC53kQ0Kz2+JNosMLM2nt5xWxXjScT9Ab+Pq43JcAi0sIkMpdrT
# DATA HMr2s/bO5i5AX9jLxxuf4p8fbG5+D/8+fba99zH++HRzY8dmVso2KofeBiM0zaXuIzMsthZJRnjpyG/8oDAixALUka2007M341zX
# DATA 7aig1lQtOkw7A3RK1wXtayApfPjE7eNK7qsjeXBgn1bzmgakT7eR3PudP9tuf/zsyWNs/zKP1B1Yj+jC8XVFvNYVca/m4DAdUXpu
# DATA 4IgBUKxL1TCK0xDibtsRJX6YjgaAQJN+HqF3JF1YCSlhg4pGtHlxkkxyspfudDj7wCk8R9xBJBe84TC4eJgftvxO9YWD1Vz2rSZk
# DATA nelMGQijwMd12J+GNkYXmmKuy93W+Z45/JM6IrfsM+JZGvlbtqPWlhc9otTIqvK6CaASHU3GE9qqPtqe5hGZWxq5ks1eh46qUW3h
# DATA sKecoRc52qdw7hIgaKLPYHPXgV4eA1vPQzxNLiPotc+4IOmR73+UD5HgV7AjOSYjxAUHFV8ZtNUUG1l1xFWKYw3bN5CBNXQG3wf+
# DATA FHP6BQOD5LVSU6wAsKsvr9RXl/dWVpt3P4D//2EhlEIsI32Cu/khegtCfwLCnW+7CnA09cKirpxQ2BbCx37S20W8TiFxkFylRHFo
# DATA zlMhfF+tFoI9xZZ+Cy1v9UwAFEp8xjiEuVj63G0n47hApu2rrxucud1fO6uuldIqo9AZpgd5F9tJMyYWMG2hYXRFSlWjOuzpWQ8d
# DATA AWnVBj9izXJ+knQH5+gomFvTMM3cBHwPUbLTGfSa1l0QkoukrhKYhqXPdjppqQdUF+XYqClXU3S/q5hRs3acHl/AxqHcqWJNRUn6
# DATA zASfqzdU0p6qVzzPTVE3uIAam0J9sp6+G4PHLyiBt5TeV62wtRfPsuqH2w842E2XaOuxGTGkK3K0UlSZVXN7UCN1bwOzIbYnhIzx
# DATA faJtgNvnEvi0ujLPmJ+rsWp5rEOq2mSq+HHATyJVR6lkJHNBp1wlniLeooKqoLBV4ZFtD6LiEbYlu3YaDYvqdwKglEu1DS1rmb+0
# DATA 4bsCHtUGRW20xKkqGhz83K8vH/jnZCrbsHyvdm8N+QborjrPxtjutizGVfK+JMpPUE2EJ4Jlxr30OOlcBmwkZQGL2xNTE3TuyEdw
# DATA clhk32oas2nLKkpaI5wY6mb63bQrs/l29EhvTQREERyWMYkolb1SlJ7BHM5PUm7/lCQ3hIETjIWEpjRIwQhDTvwjQ6Is7XWJynRY
# DATA NnNximDFhRwETdVsDb6shRBYGeY60EBRIjHzqByQJF/UurAWQR0ztLZDqkZ9pbDQPr9Ni09Mq45xHETfiJ+oNfNZt2sXKajtTNuw
# DATA ONlxn9DRVQ4ryyfBFW3kTkq+nI07KHKVvjxBJE5BKq/tA4UYz4wwWOmAgJYalnE/UeCnjZ1WkmHmsN4KTMJ7JdWtkPQJ/cvQzp7U
# DATA zIuHl3V1dsgq34EJSJJpd6HkKEXFmFET2PE+jOrTNsXWWtJiKnNLlgTbAmewzTiG52HlmDzEq6U8LXKSMxO9iPod0uxg1lnWZeBa
# DATA Ghw9ODrKU0tMvlSLltkKwm1UxZmauVbf4RZbSnLIjxRX54+IuNNfuHkXsRGNG479Qp84eOR+TE9usjLnAx1uqlE0hceCRoRDwVkw
# DATA 28F8UJWWX4wPVDROYOZIEU07tM7SQPUyiSiIXQR8dzboxp4nGRqXShTOfRnNQdEzsShyqnLoMF9NVD7uxxNWlqRCinHX5MyWUzgv
# DATA HINOn+a54aV9tEGshMZRXee1ULwLPlT9hIJUgjxpaUvcMR8CUfzKR4XOguAwrWYehlopE6co20A1bd4jg/mtdm8VhhdudJOaEB4U
# DATA hd4pKqdEpkHG3E6kabFvqnPPyov9SibXVLdVDm6Tx3DtQAwqosKDTfqeSTe5Z7Gx5GQ8nIzL0rqV6ZPZGkYPmaQBuAeHqEuGdg4H
# DATA aE2DrcUl+XqdzgGuDXpnSvGny0pYBTsldy0iU18Vv6kW+TEXsiOrvj0pPBFJ/7JifQVcgO1X5xGpwryAg49QT3CJjIyzAMp3Km90
# DATA TmBAFQvIWkOT49RCWwmeP79pa2sHm/K1ijkYCfXvlrkNx1t99GJ3r73xfKu99+x7m9sIXHdU/kKygWL1cKTzkikRcctp6unGzg8/
# DATA 3Nhuv9jd3NneeEriFyUzTbpAPEEL2qTHysmmyfhwc883dnd/8Gznsd2cqoJjshZHGxXIo0YZSKFpnEFjWaSi+lqIeEL9tHm6pu7t
# DATA WrTyhF+RJkAP5jY3xHiBWP+c3EeNACyIuDIhJepcBSM6GPS8H2cepWEzI3gMDf3TaimbZq7RpgYN4cPtV2eLgbk6lzccFd0XbKdr
# DATA J7s0SB/m6pIJiu+2DjGNj1BvO88+s+KL1VhTmQuxsG9IVoWmqI8pPnzD5BIVtTVbtOtqXwKLIy+NvFPZFCueDHgLZMt8rS87Cbi7
# DATA yzSe9aKmxmTR/geFOMK6MZv+UtHHFNOiCukmq3PjXgsS0FJy9CvW9Hezo6OUol0xR7BOnQ5gzRCXAMXrYWMyPtc5nGUodC1k7WO1
# DATA +PBS/bS9KprB6VrhmpUe152G64GmDKFrERpwlNpEU3N0qMyQvQvuExScQJoyCUWzLKjdESrZo9KhCIjmZY2vSxG0HUDYoGW+ETGP
# DATA HheNfsAbOqiUsrDpn9xrJdRDvdKREArN6MoQGddIHSbdS3gJHCy5Fk72b6sNuc15fiYquAAWV7JdztLQAfKEq86ohoI6QNvjXLrn
# DATA 4VevY3uIJLwhq0ABG5wVAppoasW/SeGicTK3NQuGPR+lMILjk7HWm9sYEfh1Jp4b0Q5pPiKzDa7jSnd02Qaix/dUiB/D7sF77Q/G
# DATA inkGg8Wr43p4E+DGxi8BsOKc2agzfmSbFpMyf3wClwSH9h066RFUQDRH+oXLNC840MSP8ID2yueLrkTWYIT6QMG8SIdRhH1AQlHZ
# DATA cPWCl5GeTFYUCpAg+24zagQMUAfK6XUETBysKzV2ACyWw3UT8G86rDUmtYFgfkGmrtTcyqOgSogHvqwGIheaEVjmns1wb9+ONoxt
# DATA EupXgP7tDQDdiowp0iE52AKdDIkxXEW/k2E0ZAoXHR0CgdrtXTIP2Ah25Hjmvv0Sh5dZsb0Ke8nnacir/Co/kvmyNBu9XjM836MU
# DATA 799Q3/PxwKxH0K0bj7rWgpgsxMU5kVj6BkNXTZs7M7XxkMncbNStuH1AQ53UTJvAjsLXTpSh0NkrQZJqAnLHD4LoUmjhAHq0sHcA
# DATA wYkwVFAcd1WKDXc/3li5e2/3xdNdsmvhDE/iBtHITxL4WBl6AT5P0otudozXk8Q8ESGPIacHhOeX/ZjVQUQBkzze4tyOe4PDSnxH
# DATA QH+16uJQhshdwWKyTLflCN0+QFRnY0a7kH7PxZRZm1OGX2IBg3X8vZiJ6JIRyaxZ/bUeWctNcqWcup7Aa9S+C+kleAooP76mgy5d
# DATA qjjohPxG/sdFb1aih9CgNvadgNcDxS2wE6xT0ovLSs3VE0sO5u2AWJc6si7KrZks52DRElj21jJw6KFOiEorOgbbtl9Kdmgasz6X
# DATA DQfIkzqH5UrISrAVc0itMUwhDo7kktQEodIlXShOqC6c0LTayhs46AiMJ22ZpOQuD4iv7i4tWfQDW29WYrPYzWj5v/7kf7mLdoDM
# DATA b2qdYoCn0xk7xN10ptvnLG/MG/IilssmmQ//m91n248pCnEpq8IA5804Dv1WAxnKXsBUJdGXKLdhK72GpeayAAB1D9QwBriEJlri
# DATA DgXdVss9TJffqSPm7+k/P0PE78H/8+7K2pLr/7m8vLx69w/+n79f/89n5/1o0AdiekyxfLppdDxJRt2I9BXr0as0HZKXE14wwCEU
# DATA RYDsUi6NDdQZXEgsPs0TNBtKIrW3d/M8mYyznn4aJ9pX06Qq0X6g6ekQr/rCwh6aCEYqWx3KeTlqGc02Xth59mxPSdo55qUuV6cA
# DATA aEc6KOPCi+0tr2xO4KIrf8uqNlRooqqlZriDwNvNxEJ+LU64PlbPupliuB5BP3GCwfxV0kQnGaIVXZuxPr+ckoiPe6d/7UQwapz9
# DATA dHw+GL1y7Ou1sZve2EY2bDslKddM1hnbkm9j1I60fXbRSylWxlJEsXvpQ5a3T+EvEJX52H09oWR2RMP59KIdLGsjkmIdcTrceo7t
# DATA wPr107Ft7BA7CiDOLY196f1BVTiqU6ARmEx+QuEzYNUPR1kXSPFaZHLPt5a0ky/HoVNLQc9CdWBtktUTeY46Yt1oNfpxdLWycu0o
# DATA zeTLw+jemtLGIDFWGVaVWDHj/Hya6BjiP/fu3l29a7gBbmXaiilpHl50Ku3q7mS6OJDllffVSKZb0zSaaE9TW76L5jSHnPvzEEej
# DATA GptnPI8xBP9Iqiibt+Q065HNZza8R+5qcTNm/a4JzpcNY1eDdBRfccXrKMfzGl1R8Ws00EUnQiGQ2Gi3FVXiLDsi1uqK+CwkXJlL
# DATA s33wrFlZW6omyGluIt0FUTvyUSUg1hYkuKvmMIW2l0zeTRG9z/OsI0ccs5Sy5+khRoihhRl3hlGXmrwyzetRk2e26dUet9yboziO
# DATA Wbud4f26Ikh7HV1dLaAVBLRzyrEh4Q3Nk4q1BRYCy9hLgJoWoLMeXV8vRJR3WAg7bIarARxHGdHJYKCIPqDnBiM0YKovLwETgCrU
# DATA Sxn3OtRSW3i7N7gtr+FtZ6wD1vLidEeDIby/4rOCUj9rRa6iK7P3p8kQidea3KjqNYzWNGxq/bGZs/56JUt+bQ8hJbOALD9JuzWV
# DATA L7Sj1KRsuI6IVjdymo6TqLdGdnYAeM/u1bPOKdxx+OfsHq8SjLjfrffT7PjkcDACfhQWBW197ZdJF7VF9G4Ei56qNzgduFSwxENW
# DATA vK/cvXvTzh2Otj9KE9hMSmQ2TDCdRn08GNQPs2NGM3Wl2adktbBXOBboACqcOmvLe2TOxhG7PJecDvV1xvmY4yS88U5dCSy5tgcP
# DATA /w93xcSO66BESwsgBDkgElgQu1jlFFcI/hADpG4/era9vflob+vZNntHieWjA7pNI2QassbBPfRLtJAEzNrNjrGixajhYMgeBRk2
# DATA t3wotg/CQQpdiiZOQJzERG7mSG8ChuOcf3s4wnEXDhwPFMuHM+A6OIVu1MvuezFlUg1m5nMGi4XUSuzr0RZCPZantXNssUSKrMC2
# DATA 8aIhnTdNtUtIipMZEsondy4JF87Hkhy/RhnsdktwGX78U29BzM5lttGirYGwo5+W9i05f9EJHhpSfXgLx2mHctFe8KF6JmljbKN4
# DATA Y0FEK6BkplJdx9Fu8EgaMowGF2+IHZWXIsb7T01jiZANK1O2SVtCUgxZMUE9hyMKzcaltrrxwX5zeUXtsqLkGBkzlNbUmibqOLEu
# DATA oSxYxZ6mRSx1Ny1u/2jMnnkcHIEq8Pqm+ILwnKLcXRJXtdTgAZFbMmWKKGs2j92GrIo+ft/hMDRKa5D0mU6gLY+gbW5O3dGknycK
# DATA hlSO4m5KdlpFdP2S42CHBk7kueB9JGloybTsSU2n3qF/j+jfWJgYq/9qscaUspIyDNHoedbvDs4r6KAvv7Ut8wYhka6eNYySfSU6
# DATA vQG6F5EtM8zqEeC2wwFRUsjlYrSLSG581BklANRNeu833Pnghk1rbq4df7Ndt24CLNL2IBqcow0x8/UZmshQxgTULgHHyDYwikfN
# DATA Ad9lvR7HJ526KDkthbcksaZ84vnWh+wwzNaGbK0tB7wXw+NRQncp4hwxMidSzaIJjgotw5eczC/GOZ/YSOWlatjRYctOY8WNAojp
# DATA KiI24bVI3BuTti+t+BncLuwFEl44QrdtpnCn0JR2W9Xi7eKbTj7EfClmbFZMdO775NZ9HYfBWnCj7E5hld6sR1kj/Ll895THoKCA
# DATA HbvX8/An349phpg2M7STHk04EkUk5RVH2a2RoGgwSsjcUgmNGqevUJwzRD1ai7piw0pyYD/KLlpxg85fPRS32Is2edQ1USaxbS/K
# DATA JPbG8+QZ6q/aQlIPsBDXcpAbp39TyAQtphBUvUvn2g1y9puRFIG6nk8k5CoNqCmhUl1igFHJmWf4Q4pjRrJ1Szo2OTpftOLI5I2u
# DATA LyGjVMVVs6/fNDsMI0SxDAkWG+cnGRCeMbxzAw7Ai9JMvjzpgvmses/npvBZ/Ky8ImRhG6iNwKuC1Fx7AnO4RTwBkF8pPM0oTw7O
# DATA fwTnZmllZdr6vOijZ0X04qMfRNZ+qXZtTy7uSCWYtLRKwCNKXCNViIfhw3x829htb+3ubH63omqpsdJs7JclE/brFef4FvPkO45y
# DATA pn1jGryNvdDxOXgJCHncw/yl6pWSqrzs2wpjDjLaZdm6LkG0aYshuHh2miUjxT9Kczmdp7/cbEDmLC+ugFYyLq94GT/L2qgon1LX
# DATA nMVlwKBO3klQ6EgLQhRgvL9U/wDFe3evFwFFvUTNLLdVnQqCccVlJJQVYNI/ldVhu488BEkdAZTnZc6ogVtUYFls6mzw8V4Uyzir
# DATA fgahClxrjgkeUzZ7lQMrtOfltTG1wxy1yOTGLHo4Lphp1kpmbdD5vH2J5zPtugDxeaLeOwMsDm7q7f8aZlA6i7CRkXcg5Ey+oz23
# DATA I/+j0/Jo0NNZY1lFIOqBN8KB0iJnsT4dnKVOYJw3xVASnrlpgMHN9BMi6SwYN1jaCXha+Ua0EwRBZZl8NcX//zCwnqiDlTSu0PsJ
# DATA jFBb7ek0iP/fGpL2vxH6eojY6wboO7xIs5CqZQQDKI5iZzkix5c+xn/E3bx0kb507qL757QVoneqIJ5M6kcb9Y8azcWD96oK8VcM
# DATA Aq18p1kzT9XvVH2M6u8KjXLmGhUXZyrG9U+Sgg7UGYpR3bBkCJ+YhDCVbrUEtiCjzRAEFSZkOMbNrBwo5/waGiFSDe/2zz+bw7Q3
# DATA QO+X8QAGMhifkPcMCTZsjx2AuUjChfczNhFKgf/WfjwB8OsgjjuV/QBiO7BWhsivfcw7aZAdGjjEJkhHPB4QLuxfxhoVwb9VK2gq
# DATA 2Z3ZF3cm8qVpCC6SWbiJemdgdw/Tine18h382hCvnrczD32ywjQhz69AncyirorNlyzVTOrDDcWAe+Vw2PpekOVM4ZY0F248Im+N
# DATA j+L9K1i565sCJdF8ax6E1NslGs4g5TznRprDOFe2JXXcPXIrsMoiHKYMSrJeth1GTRNnPEF2yEcZ6KiN6TVs05opxBDsIRoFFUiG
# DATA Cr21+ahpug0pXqAcyODF+2Rjxxl8FGNAln76TrXUqp9f3XMD1izuWTaYwARJx+kk16Nx+zm4bSRKrGm4lF4cO5K0symEl+3OlSKJ
# DATA yjwn2o4CVHByTrumYlapbecTk0N6n0v6oAI7nLApZqMMq47Tus7LaQpYrtcWzVyzFIRGr7ugbgGpCh1bonI7Indn3lIVhTI+Ulqq
# DATA baIT0xgizgnsXC1C0zbjkorV2bIGmnHRULngdY4Ta5FqAPNQ543tNblVX/hhiSmrRq5RHJ8KZcLW2opaaBUZIB+ROGeoEFzVay3M
# DATA 9zlN+AA7sPZ0qNqUEKnddm9VSWVnlywbpCvJFNaMZChxnp/w/WmqU8ax4vElvLNlte59a7rTwDij+qo0rTtyXRgknhq8TPH+i342
# DATA Plh4bKEeQ3kR+yY4iNZiYQOdvloCe9ECvyExt0SZLIqUhQ8Jp7fIKpBCxEi5hf1dLnGwgFbpLdjh/GQwXti8SDu7GNivpa1exeI1
# DATA mmbauah2SGMaDlpIw0Rb8NZlmi/sbzGVebDwgwStyT+8DAwsjj18GbNpaGdMydG6CeD3fn2UksPgtJJpX1312Uallp9TQcNtY+AA
# DATA 9i24B3on30LLBXWCDS1qOiJ6Riq6cApw6+JNdVpUIGwmPTrd68yinewh+pScvWgK/orthIQv41dlqnGfEoXp7xM8LZ9g4GRweOB5
# DATA NjwA7+c9cSVVbQHX15igkZX8joeQSTnH507mD3iUfyHujEV/WEeFmn4gVT/po7OxVU2L06YnH2TgObUIAUzOPBhyhVqaWjkZZn7V
# DATA ObMcWhWmdUBgmfNP3ihToTIKaenV9b10hGCR1HOEW/ZXVihmhQSPsIiWMh9wRxiEZO+UVG7xjhBgnnl2cMjOHuswEtPJ0bD2zs9a
# DATA iGYlR9kFBlSG8dTZdsJ4byZnA7T9wlyAiySHGAHUyKOkMxrkxrRiZAxKCkzEN0DYq25vzHa88dhwPazsjWofKGXjG2Vs9PTnnHsx
# DATA rEG3czQKaxzO0Rg4SX5eXlsMvs/x4hC3SeS4fsT3Aa51aXLNYKA5Cq9VSOZgJwHmG+bdK80ocPAnw4W4GqUZ18Od3RvxeguBHOre
# DATA mIx9jcdm0cXXrJQ/E4ufIiWCvbx24PpSDnFmlm9LiON67dxAJ+M0Nl0XY8eUg4K2rrZcY+axFTRhlQT4oBbJszP5gylyq2B5Y7x6
# DATA MxaD3ldnHDnCvt5BsyxEfHxRyP8+J+B+d4d4alAMvpj+LkydxGwJV9naWKfbMGoAC6vV8ugRs+4/E1Hv+uLPknWUMCBMSBTOtKdk
# DATA JLU9FdEc7EG1aslIytdpytnkhMYlVKN3sGxz0wKe0E1Mk4J/bfS8s6A+r4FMxlws0vyMqBVr55llPMoAp7sesb5FTUGEXNrPWkfh
# DATA me2TLm7o3/rDf1+//zcCna8xA/BU/+/lpeX7y3c9/++llft/8P/+Rv4rccpO8jE7XpNI5GJs+V7LG9YW67y5HWRKtXd1Ohr1ByVZ
# DATA fE/Gp70bunrXoueTUfp8kGcXJZ7faQdouzzo+m1y/1LG3oWFRxt7G0+efbf9fGPvY0X3GZErZZZHsIS5KORutIEOTHqDY5TRVhee
# DATA bnzSVm18+One5m6Edi5OZj4q83Rje+ujzd09XWj53ur7/Glv8+nzJxv89h6/2t3a22x/tPXEfoePujZa71mtb36ytbu3tf1dXQe+
# DATA ux9UxXtrgcHpUo83n9MyvL+wuwcjamO0UlSMN7T9LWP/hX/z7MXO9saTQIG65aEhhYnDCjRFbN/Czuajza3ne7qAaekw6byaDKWR
# DATA Z08et3f3XnwIRQ7jB7e6AzpkdIAePsB/ox6gk9bttH/74QNyQgT8MsLo17cn46P6+/CW9J8PRRj8YJEfHwzVG+TETJCCB4vDhw8W
# DATA qXm0od96vLm9t/XR1uYOG4JgqLsMyZZ4P6l/drDP/sz1g6ul2tr965eY8uzjzU8CZY/IiOPeGpehuLKlpVZXuNTmJ3ub27tbz7Z3
# DATA KTpdA0dF/qYdTtoBS0R/8jOKndMYX4zlNVHpceNCyp+nh3BVsyOg/OJrnWN4FxabuXfDyBdzUbeHSTbKKySq9b37r67tmPo1wwhT
# DATA 6VBkfa4a0geZ0cSPXzx/svUIDyJGjWl/b/PTYvYDjL3vZKZw8h6oseNKVNCGqNoManes8DIcJYECalWDqVjJFKlLIWyAo8OzVfSo
# DATA sahnbm9wiDmfeQ3b6H7a4t+u3+GLfqYj44Tj5dSinbQzGeUm7k0xfk5hHbe2v7/xZOsxraJKjciJzmV5CMR5XhNepHYTq6HqGOu5
# DATA iUqW3yfZUfzyJTnb+wnH/YG92N7d+GizvbG7u7lHIDg2GkmExjagt30ekBdUysXkMB/0JsChVlm2MKIvJE7gYyghy5VrBodKuOt7
# DATA G86MVXBghy2gi/4BRS3AJoO+i/iBs2416PI1OJ02vm4As5MjcqnAt2BlbxiV7zQB1f54OOr/OJlc/Lg/6f0Y4MX+Mgzrx73hmH5U
# DATA odDLRuNO9TsyKmT9G1tF/vBIRqGUompVRDvTyCdHR9kFHN9z5NmUeMUAoeob7KiTa15OXXdAdP2Nz52zrXL2HkYrd1fnuAKPnz3d
# DATA 2NoOGZBrYCZ5NyVXTCPW+ZPjrNtP4FHd/STvZBk8y0LZN9m+yDe5oWp49h1VB56D5VHkEZ7utBAbcmbhSNio6d7ytfpCpwRQXdqr
# DATA TrVMMY7bWNaAbmWj10AbvZsufBBGo9xYdG9abuxa4TBQQFhg/JZ0loIQNMBL555ydciRy9QtNeCknTgu3WXnmggz61jjwnSSfheT
# DATA KRHC278zwuCjOToWG18w9C/Gx4MpulRK3toyrTV6nrmtHK2PgEjYHow/QllyIIZqIU+WZAAkC90n29+rYD+Ode4xEEtjAJv4gVLq
# DATA MPmL77LDCWfSWaqi7P9izY5MF1wnWqDdT58+2dr+npsoyywTGbfBFih9jB7e460dd3gzOrM3ZWP7EZDXz3bcTiuDnGNfolBhiKiE
# DATA 1UDlXQZNtewS2jJZDd/7qJv+/t4n1XlW6wc7W2SZUzIFs24ta92MqgmoVpThvP1q0mC2n+21oeLmIxjHpzceCAml2OK3YBleOHfq
# DATA BYmk8FAszz1CaO/Fk40dYndckILjUgBFpbkYn7gQxIY0RvxVuMr6Iu9z0Tv2hT6oFhyUzc0NS6Tbp8mrtK3Xq6LLUzaLu3fLbwsB
# DATA KtN8AVpR6zQpq81CsiNnadyh8AStQ0J6tTbPVegpwGL87Jl4lUeUpvWyNJHU/hS5KNxVs2UNDrGrKxJSaB91W9wjt1PcSZkfCqfl
# DATA PcWoKT8AlhyVHbFbSvX4bPvJp9GPNXgcoK2TUUMyUCx8/nBre2PnU/oYUlC26V/umbqjIPuHrK8EiiNNTptF5wSsT8iASzQQPvcH
# DATA lep0Vwyu7lw588pcOve9+FcE8suGbyNJJShNrAUshFGS0dJecKSg9+CO61IczHvW7CRCDfFuamBkYGvGnPUHNW8K9jPlZ2/3Oa1Q
# DATA hXrVtfQTV9KPus4UkoDm/+jjje3vbj52gRAOFk7iH3vSMeGizZ1qeodYe447OnqFwm5pFGYGdYkZFVyVsaXXDB9oetIw3levq4Q5
# DATA ZKkzGFnaeotSUoc3HOLH5y3QyYmIr/3lppdSq3OSkWmn6QPZFmpcX3gzmKoPLkhBUykr4MyCegoRXPr4lTWD4oE3xP9lsc1vQgLw
# DATA FpvBhb31g4shwNCHOTq7E5pRvEN4X3pqnH7dxQ0qV0vg880UqDOPR1FNal9hd72tL851YCTF96xgpxJEW7InKBtSkuRKSChl8kYw
# DATA MrMF1Q3D5dSiggTaYUQL3MI83ChDNmnz6dbu7tb2d4s8qTNcHUJRxu0LyHTwifjliNzWYsdZxLjRq25RVoXPBRTHGaw4IzeJUJTH
# DATA uUgHpICRsGBH7G1GHyjTurxF/DcDyyn+1VmTx/DXGn0PU55RRkTuY5/kTTyspp1dNr3AAOI5B1pK8jFb3lWkvtzLOD3zkwx7MhHT
# DATA TONw0MVEUtDUowF9JlkUh8bwijVEVCIGR4Bt38HUEb/JXGQWbRy+37fnGDgcVbAibYBUewdjGSXnFJflYqwlNrZ4Nixk3b3sj5OL
# DATA oGx1Rkalm4wxIM8hcU5yjkRN4QrPezdtwkuILhZ1Y8MlAjWWR3MyWLwV6ViIq1uoW8g7J+lpoixlcxZZ0mnCQvvq+4HvvO1+9S7W
# DATA XCulSKjBeS5C9n0Zw0HJTLCo5AstiKTxG0mkHQ3bGw4poOaA9olHhG4c/FgpjtFbbHgjay35jlENxR6i2jyaPEGznqx/AWsV+8B8
# DATA K2wCZsSkRmVliwZVWSqmn4xcL9SfEjJ6faLqxe1SvW2w8LSqhLTqPR720+QiO52clkX7w74Go24FtXewgdHqCnPm8CgLLi1pZZNq
# DATA kDPZq+XE5BOYkd5d1dV7S9WDavUNgI2dLjYTZy1cPd6mgynQmkpYhwA/r6pzSh/1QTV635uMkCo46Wx7XYpPbNILq2PL9IrlfUH9
# DATA h/0vWCsUTCSFLxsdoL+wqwplwJVOiyl+pTNzUOKXF0tLJJZV45BTIo8+8FYQ0ijA5yCrpy6QzCK+umKp9PW1MxxF2NMsLU0NqV2r
# DATA 89L03HQbAM+jzY+fPXm8uYOhWPc2P9nzRsIrR5FJvXV1RZlx1u+mFzwKpZTho4iLura0Fv4UhB5XcXKIEUWVJpmeFq0OrjmNSM4B
# DATA XeWYziWf29n8ty+AuXwMlOp3N3cN+bhgi4VyOZ3crmN6jUk8xyo7bVU77unj675R/EjfUxbSsVXCOpaBmzaRk27Ec80GyW3YtydP
# DATA tlD1VVQ/awh6wAChVL3h0fpSZP8KQFhTQzU7K31lGn6oXttYyOMmmNCD+3xgxGFkXMnIiLRuBQ0+LlhTXQFDrVtXpEbGFirOEzdT
# DATA iyjjOlsRVjVoKFwa44cLrS8UlUsFuCR2nzaIVVBK0tHLWdE6wNlgw7XRFzWWWivGz5PTaQ1Or/8GdNzO5jbCBZuMC50d3j6yPtLr
# DATA jqH2MMC0bCS/RvpPtKqyzTZN5R0THUZPWlKAw6VpAkqX720/+8E2Q1ZFWbmDt85bvq+aP9BHTyv8LvsdWxBmybpaAVnXfDKK6eIr
# DATA Pmc3kYcF5c5ByQUJknBKIYFD0B9ymtDGdkVkkr0gtLmBNPsHO/ZkHR+bzU8ePfnaxdwi+kHfnBJhtwh/JQ0eMiT+p6PeJD+pOBEt
# DATA eb0LcmNZQr6/XS8hCZ1QO0GDWBik/RxzoZBSn62r2fq8DfBYJUnPUwxAD9uUtzA6TQ2TSnD4i5d9y05AcZ0yDqhwmnUCsUlLds6O
# DATA Mkqn1jJDtAztaKkozDUlAMN/1iqUAVCUI7yWVrRPb0UC4tspkrf5r98MMeE80Uinu+qGasvVtm55Puq0nbsLFykft0uus4FGDftT
# DATA KCyq6bNE0VcWDVV9CAr/nQV/d/q3OcLhmfit1uqFxZZw05D3GyiFmkTQ4Fngg6e7YKZwMC71rjS6C8xXOupawfMpBSA8LjGwA5TC
# DATA Udf3pSPg5HitTtBnS743XS5ohC64QwKTUqAxHAwrVe/Aq7KuM4SDRhwdywxMVdhBbr/0wpTiLK73tWIt+DrKUkEUOemPRxY+wqna
# DATA T1ZWdiLpZGbFqUu7zaD1GX4kIre0lC0k44MBBBYzyZ6xMwqfaIsfRkVb5mapbVOYINvb2SyqM/07hflwOLD4Is+ENig8BdYxcSnS
# DATA MkHN3uBc+fnmIT8ec0MwSNlZqtCAem6PB3wHGwn6mMHZq1TLFnC6oQtt5tvY/5RpbcKBF8zEaEdVlohKbPyEa3rW1fL66iqr+kIl
# DATA 0SlAFXO4ZnnYhzl0TiUKQVGXB0zt6wy/mlON697wEBro+F7LGUppac4JDAfJSx9c3v7XYQwRDLnxFgYSof9uYDRRsrfv0JDilrs9
# DATA ZLegXmT9AV1Bx47BrgGP1eZM28x5zBLK76Gk1EWnCmfkU6sxwtWVZ4/xUPz+bYOQU+BRMcbrvZppqTrbFFX2h1qc3fHbLpC5Og2O
# DATA XlehjmdXMitbZznvHPVYSKUXaPlr3vz5zG9KBvqNW9+8y9kX0A9FGjOYpzgdOQNWcvXqDNa+lGy6gaGCUMgeyNZMnBKRCXnkJn/X
# DATA MhZ0h/aELNpe2gnzbltRh6KQeOS6o2607e2K3m5u2qU2hWmGUcnYmNeX4Ya+6XFX3lCT+SrrsyRVJFEkTCVRlNGz4WfgbYr6tjfT
# DATA fZrX1Dm9jEPpLPzuAlPcNwOfR8PnVym4l2gJIRWUhTigVXNfBZQ5XEAEsmbtC1PQ+i2nQkDPVdoH7YY33483PylOlMrN5YLAtul7
# DATA RlxpJM9CH2X9yBlwUTEWUooFdOzU3NTBU4kbKSLtkc9haIgIB8ADUMW9wSUGggpJDc1X4GW0n6ZDAZ8mo1eEKA5DB7h+tqxSDLmC
# DATA JFt+yU0U7JI2Cfx4PgxFvwjPnDfF+LPUHh1Z/n1TjSBONS64VjxPRxQZQew/AjYf5Wjnwxe7nxbtPByu3qZt7fBG04jqgIwutEK2
# DATA NKI/jgOB9Njr+TQ/64zGha/8mhxygWaxEFFNfXoCJ+PDJ4++V7MteMu5qkK8LIe1sCIx2V058ZhgXazn7Q8LmyU5Gt/BJmkry5ub
# DATA VsJYKIpFpZceob9ddnwydhFtfpk3EBIDrDm1rdZiQLCTi7iIYenqcbSs7FCkwOxQ33j0+MmTCgcqnuRpmxzrrQAeR5O+SuKnjpQ0
# DATA wdHx4IAk4xU4VuRUpQapaxVkiIUBqaKNZHRMI0JpnIyt06aAd/oJDTbaQ+vFjM8T+H7g9oIBatDHu+U0UpSP4toTf4g/2krWq77y
# DATA nuBn+tUOCFFVjxWnASKMRaSPH+iGVWtOM24p+qKKrVAq1aVQrjoSj0i44641P9g13lSjnKMC6ERK7xub2892P92tRfJEME0/PXu+
# DATA /Wxv98Xz59dT9pAvhlyeSodMVFHyB3hUvzEqFAzkoiPeW0l7Hem1+m5OokIuurwnFra+hCTDYXuKTRSvbGAiW5a17JrIf/NfssAd
# DATA mXm5Sm/PzBsUnM3G3rOnW4/aSgEM+Lb9Ynvj+xtbT9AE3Lbj+Uau27xXrnDteNtZMEM/C1fPPjBYzHpulyiO9FX0mrSvmRjyyj0r
# DATA NuqWts+aVFn2o0wa58lp17G4qzOvkY42VYqgSZdFRGXomi0UUeybnSdWb8nK2UoB7zaKPumWMmVu+PvUVipur4oGGRy1g8L2WeSl
# DATA q/jUZicMKCz3/mBcRFY1mMbUKBejmHvLY/ytiVJk5xx4o/prWY2Q/SO/R7LfbzwXxYIqbSw+5PuczsIfbjz63ovnbQyhNs35mWId
# DATA Fon1sAhA5WXsA7hDazEymLLqFjTRQdHAKDlXbHYJj+BwByYijGfqMY3zL8ZmV0EGnIQJJhGdNljqpEBpOQcoGXVOUC/QLJM/SAEY
# DATA qx1TZopE4h3IFMwAtQihJoHyvmlZgsTLKYgUhKk3A6UWiieuLCLG9GAMLlsrl9gxlNq3GfWiOEItCC3ZgXPttSNxQTogpWeLB6Rg
# DATA tTq/hIBvbGxTMuZkmVvgMMnseuAfQ7twyeUIlq4GUhnoA+vBArT0t283gTsYTQF8EtlihDyyMLOoLgFfrlC12IWFHzwRnvFHCEku
# DATA 2CVyhGY1qXPZLSxSi8aDVymQkINetxb103MJ8qiyJNkxItQ+hEDbgom4XjJ09j62unbIPAtFmLDI3fQM19Sq436ciyvlNSZ52Ke7
# DATA e5tPLRpQHQ+nCzgsFStOFpoA0RJZZg2eg7c0Q57mdlbgaTtpiXHCR1o7mQRLujBYS601EG1GywqONqfCs1qB+LKBWTMAyRQkbtKR
# DATA KVbns9+M3uYq2fktmCZS+EmdMzaWcXBofH5+zm5neAgBbIVPKhaADzfzPRaE6K0vnQv4LVdI6CXJ1oFkg33aMZlHryvLBvRUeg6/
# DATA 8cI5S4hldt/BCnqtqk2Rux3z5cYX9OPa9pvSp4lwszK99WLs3YlWZq2grmFr25W9nrNzdsA7NsgMhhBimugo62f5SRk8c+SgwkFY
# DATA Vq6c+9envujkWBaRyXGhiGMcSCVCkMHKGTQPRCl0HZQ+uhCV8DaffplNVWdMMp/UQEhMAi0E3IBJ+qDK1dTS+PLH+QbQwvRd59YX
# DATA WqEpnWvRnjRR41WvBryVmSNyEY3tcSibXDPnr+pb6uV5ML/GrKPEzfwIbkifbOVKz6wtkpTiRfWf+vDGGkBpoFZyHd+e7GZw5sIx
# DATA gVoCsGoWfNKUuAEn744mn0NtR4P1iFSK+FjUYnHRaph2tyZ7oMLk26cgRLkXmegQNT0nQR+OIedT+LgLB7VIP/AmBEj+4Grh5s1B
# DATA 0FOxUiaCN3luLkKK616DvlJeaDUDJe04nbGat2rzJhzH3s7G9u7Goz3jYaSisIcU4oapIaq0lHtyWQdpiEWf8+AN92Au3IQYDVS1
# DATA 0I4hEQ1mmYn10oshkLLk1WidgwXLyrF42CVQPDOeeG9UI2+5L+15xCOzGJHOZEQyrNZb0VCiJzpT2An7dPBeTZ7N9qvcsTkmz8Hy
# DATA 2p6EMjiEl7PAhqrha37S3HeTZ6dHh8WsO32hlWmpAcwU+/O6uqQupwO0gM7CNEJkmizJPh0OGXADEYG01dVrrykbLWAtBU6WHHiU
# DATA HZMDl3u13KoLrlK8OC9upTr90N+Q2zd37Dh16Di1vbjq+KwXIqgH0RyRzNTmhsJjfINxGrLR7aUW+RfAJ6XD1wT5DW+WUsE71eVz
# DATA N8cywF7TUE2nARqX6NsAMWqN1A8EV0qOFlT13L9u0z24NxikBYFqxfswBRbVgleG5kzrbh+3GQtvbdEUCc9NphKYgA0CaYDzYRXR
# DATA zTx69v3NnU/RDfyjJ1uP9uLqNLilpzv7ehWnVdzJ4uawrrMEZOnbrsdEaZek8kxoOXXC3yRulAK3NMJxk7qWY7G54pwGcJNPkQQu
# DATA vThbGVpi6hUVaYQpLeLPainxYyvraH39ntQIhF2zNYT+VgjTdyU8iAiNFPoMnV0j34ni47SfjuhIQkV1Tzy5j7ZUbGqCTdsuziBG
# DATA rhWXDEzyOEt67CGtbqtjhiMvy/3QtElG2OvrJr7JWuZwE/dkNcB35OvliGmUj8XN3btY/aERhLj5o8lVyHHrKBuRk0kfs0JJCd9e
# DATA Qun5qWh5ylNvU/yaJiKiHRQD2cZi19OtrwsGMp7rFnc3r+tWyH3kLQMuF0PlPmSdoONZcovNbVWWjOqcEy1I85wNR+rJWt+CY5TI
# DATA tzRYnNJUyCVsvhE5iuaygTlzJ6GeeioI4/Roa8XgeNW3nUHIXXgeP4BpNoYYSC0dnYVsed0QfEpm4CNVV7e4ULIYIqSsFhu0XHQF
# DATA GeCXCeYCj/XgUMamMno1I/Gftxz7GHEEtCHvDh34CEfeacxlowxJwSoxNSwOyo+v0YpHADQHp+QfQj7nKjiAxajZKsipkTjQexwF
# DATA jtKUhk2Hg0EvYAqvBmHEYvoVWwHw0DTHHXQI0JFC5pZHYQifzV0dWM7smWOw4yjczN0wopyAibkwY6b0vKJr4/5dkF7DqoQE144L
# DATA Oi+38XOR1vDZpwx0oWlUhQ2YgveTStmsfKvcMqqgG+IYiThii5RzOJEFS1/t98q0SJn5v3KAOktF/DOPskoPStXzmRVrkYPQew6Q
# DATA wRE2ChBD815Bdy4bXOjRuQ4zLkywClnvD2wwYRWRdwfXvq+HfaDe+ADNd4huJHYM4IEQmxGYRViEWk42zz94ltYFzi9TWbxE+BWF
# DATA w1dOB2Wub/sHrklbbb5a2tNvCvFQ86vrL477X+kAph6VEJ+P7yTykrMYb7LUUwI9cbTtQdZhM+KsCxWzowzzcyJhYh4lApQafmX2
# DATA ITHxNpEyxTdWc61WEY9XjSAzT3tKrl+ZE9978IbxvyT9a/AUKzJTDkmmUWbLQplUS31xOHc1omA4rBuHxLIDRjpxsVQ/Vlws49v/
# DATA KkUKwo/rU9D/BzDsVCsAn4b1zYRESOSlo7hp4MhxMgIWh/y9cZiLUSE8hmAuLtjwY5TYwYuohO7Yt2s1QbHW1tzxSoAOE0nuSuZ2
# DATA x47xIyEEAaxy/vDjtDE67g0OK/GduFq9rmEsvlYvOT3sJlSs6WcSq6ksIewpEJLE+hFS+qmIvYrGOlOMoRz/1aY+pMaTtako17Db
# DATA s3g0NlWgPw/IlYXedIRts8/BdVnvYo5lW144gNIx6tErVGLZM49oLmjZ46ghtJTmVsACZF7XclvWfVMzxrajn7ReFbIJ2tSTQL1u
# DATA bFGJQdxCAC4WPidIbAXs6sqIr7LD59BWgTkZqkqtlE1UqeiGlIe8yIpxwZoWHLZNb6XcVzBYerF2uZVBoPjcfNN3N7c3dzYsdfHX
# DATA yjq9KXdhtPjWiLhU1fObkKKWV4jdqQr6PKd9hGqMnHBu5D0Rz8vYoGVRKR9ZdVjGaeXC9k/TAvZoO4H2883tx268W6PNKKGBbyK4
# DATA KSouAgeW5jenTYS0NNc8zfkOgEJRRzOZU65xDxki8rp4diHOfHVhpRBEvK3eobUs96gm9la6boFH3ba3L0FLfWGLufPZVjjGH8nu
# DATA wt8k97O9W2rOPnPgjdjpbyY1abyx5kVhcmiMnrHmjUHb5juXfjpe4/pvKRRwBQLeMjqMhbdoJWbJ1KaD5cyUbZEBBYMuoDaS/wEJ
# DATA e+bmsQR6cUSGUJxnvbExOp7gYj+nLxUr0HMr3mIEHh1O+l1A4xGAv6QXIZBV6CInwDiYjCNaN5RrYU4EHHPe0Al1sWWMMd5OpLNK
# DATA XK/bcddQLtl6rsUEZTWY2pxaxoqzAouQwMpoIerUerx69REbdc43HqGAEL10eMGYmBjDwZneG67RG1STYzP3ABV4rluHSOFhCrAm
# DATA 9egP1szpwFSDaarxcwMHXrj/fIGLLD+ZUlA1GXjBKIc+OlkcjbofvoTQi19GkaHqWUTgU/VuMm32ljXrCnP50wkMJo+s00lAMbiU
# DATA NX329VHAUXjntLBODsnpLkDNWa1a6SLIl6CotKjFn73OZs3mWy9/caR+YpawG036wJvhSuKRwaYnOUDVkjVxNCLBNVGqEXowqgn7
# DATA CExbleEogythBV7mrueJvFwtoI6lWWqsQFyQwgCuYiohSIV+I9NfHA/QxcjntjDOQD4Gdn5UGNAygHx9XXXCGRS1mSQrVsh+fVMP
# DATA FsJaVKcJDOSPjCtFH2q3SZDVbuNutNtihYBDA/p2XCGcAwv2rZv/h1iF9l/JDhvDy2+94/+W4L97a2v0F/5z/q4sL6+urd5X7/j9
# DATA 8vL9+3e/FS196xv4b4KxI6D7b/33+Z+fe+3qNounbjeXa7eJ1Ljd3L+6nXVvN28TYTcG+ABX5XbtNmWpgNev/+6rn3z1l69/+dWf
# DATA v/7i9a+++vOvfvrVT17/PHr9y+j17+DXb7/6M3gHb15/ib9ef/76t1DZIniwif8TPv/L63+Ewj8pqVWL4O9fQg+/+epvoMjrX+Mn
# DATA 6BSKQpO/wt7g/38Fb3/91c9gGD+Fv38LFblFKP7br/4aPv7i9S8b0D2JsG43r26rHCowiAe3ugMKA0FJLx6+fNl/gD+iHlBYrZcv
# DATA b6d9+Ofhg5M06T58cJqOE8pQlKdj/EjSM/pOX/DS4uuzLD3HsEjwU0nQ8PV51h2ftLpAVXbSOj3UlCagngOxl7aWTVsn4/GwjvD9
# DATA DKs+4lbqu5i3LBtf1p8Pelnn0utAiLB6PupEL+M87R29jNcjXnL/5fiyl3rvstNj5w2ZyjXXo8Hhj2D75VMfkBYWPkzytA5jsV5h
# DATA UJY6k1nmbXF1rEPgjX8jOsvyCVG94/RwMHgVUboaoHKPT5AnOQFEcjLodXNCheMToIwTQItRfoqEMzMTmFA5Qmk3vAe0dBqlSY7q
# DATA ifEAkWIj2h1PupdUdzDqZn0MuySRZIGgQ5L6FANC0qjpqD98jqJtJG+O0Hok+nH0bydZOo7OBj0g/R4scqEHZK8zSns4jazDM4Ph
# DATA HuHzYpLDeckX8X0jPzvGb0RTYtlTaH4RXr53cdqjXu2WaJfykzQdh9rDLWh08vyG1UjPp6rxVmAI/UKRH2EJJOzT0cMHi1wQftBN
# DATA wGuC6f7oiJAQCKvboIJah8vSgyZpTK+yoT2abyP6wkK78AF3R87Bg8WEbxv2atU/RMbCmY5R7WEz7q5AG/3kDGiULKn3kkNelqdI
# DATA N8Hr7DiRw4c9lLT37Cwd4T2mtqxSOZyfLM11ud1hghc4kvd+cTyCuuwOnsfzwegV7Q0VXYTxyKLihJk07GJVtT4PJDWTWYoh6nqw
# DATA BkOm5Yd7Jwls4RBpYu3QBkccfgOt1m9A88sPHwyhWBphXbgel9FJcgY/Bmco3cXMfyd0ATCVI33G3SAyE0/qoBFBXWCbyRwOKHG4
# DATA bWO8YpeDCW4dVlaCKnV1odfhwwfd7MyMm0FD7p+Mw8l47F0Ydys+BCJTdXOYAt+L8XZlob1WUD046HfhVjvtzbNpizBWPOe82oFl
# DATA lxe86CsPn42iYQYDmwxhkQC0HE1gUQaDHi73Ci73o6TXmZA68qg3IOo/Tdi+OyJoH3VHyTlCHLTrwxWG/dKHI+oOUt7KbjrGaIXA
# DATA QQDtOsG7BQNHvS8FrqFARp0BkOgZCsF51W9y/vR8F/HAPXxwBKQ8nsShe6PgdNlLgVJf5hKwXZM7CtqDgg/V3jtDMYnIsM4GQfY/
# DATA Sk6H60ivnyWdSxxQ9F/+JbrR+HnX1KgXESjhfRJcDkjfdPsHbP8HbD8L2/OxfAMk/45x/Juh+NkY/v9DCP4d4/e50PvNsPs3gtz5
# DATA RNrT1wj9v50bRAB/Nu4ESD/IU4VBNxTaZHEe9EjYXeFPe8pI1yRmmoMjcYCEucOxIrGKbJEsQScbEfIlAZ63ELQ8RNIoFJyTOK2X
# DATA JiMK5X8KSBtOVq9GCBgmkZ2m3ehwkvXGOAOEjzlPGUb6IscqRG2p8akZYA8Go3cUPZD7BAGTA4N+77IRbY0VDdfBPN+I8XHhAG2R
# DATA pNmotRUpkHQRw5B4kYaIm1InsgDvep5THKNoN01fRX8KZwWNtZRy4STtDUlWhYOMkqMj3CUkSJKjdHypZ/jpYDIyOFqmBpROHo0m
# DATA fU1qHqKxUzpqRJuSaAiXFOcxGSK1gnSmOoV4xnOiYaAAplAYIJEE4CHHMknvcpx1iLqBuaWjMer4j2EKCdpfKNM2bKtzknZekciT
# DATA VDsk9nQG819/8r/lMleU8pJdUN4ZDKEdoietPWtEj3D/I9LLU8QLmNglzlzawho41DPsIj2FnTpSjZLEFe56kgEs6qU1ogMxiwkS
# DATA yry2fTNyuBNj2myoAyX0ikTkGCAHa/jw8eC8z2QeLiRblnXgxKDFmjc0PqdcJEciHIYKtxwhXCflg34yyHlr0aZwRCT+qzQdmkud
# DATA dDpI+/cGeBk6HXp/jA1lGCERAy/RYgL2wHbyRrQ9oHIT2jUono5oy3At9Y3CRoc44JNUAQk4Pk8R2mRjngI0bV8XWLEJHG465nJb
# DATA 1a1ML4BYxCmeQ2N6KY6IeXE2cgtGrA2XcgzugdZ4XQYwEbqXwA6NMuVX2k1wiI3oQwQ+bHuAWzJCvJgCbJHjCv2g/xZ94yMl1P4b
# DATA sznzIZu5OJw5yeRvjNh/E1r/HZD6LtEE9P6dq8PBBZAvn2H6mkM6pXV4c42VroDiGfR69cMUeOFsMGrmp9D0yTW2e3WajOA0NJfW
# DATA UcNxPELRT/MsGVXq9WEyTEfV9c6gB1X4FdBl1XWEX83l+8OLxeXGvbsRf8G2qutoZQ4g/7x+PkqGzUM4ga/qMLfudXLFzWR9uCDZ
# DATA eB1j+9cnaDoKtF5aHxwdwYSajZWV9PQ6aZ5gO1dUpou5QOiS1OHwd1714e42V4YX13xIall/OBnX2H6rhjUQ11zREKUvVbLBf6+6
# DATA WQ5o+BI+U9dHvfRiHbDFcb9OJn/NToppotd/BLczO7qsy/1Sr4E/BaIF8WpzbW14sT5k4qAJKwEwM1puLOPfdd6B5vLwIsqBpelG
# DATA 1voVFhqBR3/srjTMV72W3Rwl3WySy2d+qMEIeD/q5zyme3eX1oGVyqGd4YDyXa97y9hEBkbWpKGvmFod8+bKGiaAqX7OFlOF4yBN
# DATA 7ROFirbcedptodL54KowUZq+3QAfMWmiCTuDWKV7NRgmHeAGm427d9VshAeEw3EEBEJeB3owQwwkVd2XdCi8d3xEvJfqwPhlJ6dw
# DATA LS7dt1dwtfHENFe9TaVScPb5szrLsDXXPA6A15V9YpEIjcOtPKhaL3ErBwfVwhkmTrq5vLT0PzqH7h4cupLThd1X57/H5ujiyW3c
# DATA tw6uOmyrahLe+GvWSx6/DHcFrua6DJV+8yGuF4EIXLt6fjKCh+bStdMc0OoHV2pwS9d6QaxVWH5/CdqGw5Z9ljaJcgI0dU38kb7f
# DATA x6Osu34MYKixSjNzrsnSEpdu0JR0nTJgQM3cx1b8+2+3ugatHmHWBdj/q6l7pGa33Fi5q1rlBYRxpceAxa/shu8vLekqS1FjDapc
# DATA nyzXTlZqJ6u1oYDw+ngwhOonywz9uDvkr5BM5oZqmGkZ8d3psLLSWMOua/cad8/Oa3cb+FAFiL60JiOVNamu94ASgiOBYlccAH8F
# DATA kECZNWr1xtLqXai6fppcyByW73VO1mVQhwO4n6cw0VUa9Mp8g1tmcFpbhaGt0MLj0JbfnzE0GMvKXVxOt2/qeZV7hk4iWXVocdVv
# DATA 0K1JN+MaF1hN7d79zsl1dnpcy8+O9amhTGjr1n2VA5JMxoNr5olrZGfAGF2uCqaLW15ZgoNcQ4apgjWjenQPYboeCCMpu6WZZ9VH
# DATA XCQuB9w/Pk/TPp3k5cZd7ygvL93VYEUvW+jkXjdIesFreZ/Xco3XcqW4lmrVVpbgQATxEPAS7oQILhD1gP/wxVsR1Ep/r0kcMnMV
# DATA /Hta1nuUMOYSqX4LSeADn/Roakpl3buW1w2UBl1h8AQqeJRdpN31z+okg4F5r+OlrC/jLq9jxg1YaVzoEhCtwQLOk1pmFHSFrWDN
# DATA 6waQNAMFHOucM/Ae7p0L9eAfbbOGsHdy2s+by0ejCP5XBt/oglL7UQMoB+iG5kogVpE1ZkvX7sJF4NJH2fFklGpC0rztJCQNtdpp
# DATA vL8yMvcTZ9V4n7oVVmL2WXjfq7/Md7QhBL+3NHeXzLGm0uEzLZUJILlDmPsy2YsK4LsA/u7ao6SOIgCGbilYOty5qzn2cpQOgSus
# DATA rNbgnMOmVJZqsLMANsyIrhudZNS9sjCLhXXuEar3T2E+GR2hC/cM+mI6Ocr9RsMmcv/1zknW6xanSUUaKD6vNU4nwJRe2QQCvYGG
# DATA 8Lt9eD7gNTxHs3ybGvggeKfC5PNdALJr8L9V+N89JK28faLz6WwAyezc61JCqGsEg4140JDn3OyPT3hNKiv9aqTmUrYTK0Wq7bqh
# DATA 5ab+WQcwANNCIKGLREIN8AJqxI+oFbE+/sAWUVZpIbn77+PdpreRjfzuL+F7mE82nueMwmIKxFHgxbkllNTmuoGyBU3trXyd5xJ7
# DATA ImVOkURUuKXB5NsNbuBK8AZSW2wMeOUAKyb3bDgfyZmbcgZkZoQ/1kIcpXUXVhkcnZ+QsyRCqyYwZQRF1YiaMJXxpZ4jYcIGm607
# DATA NHbjrqKa5fqtMFhRssgApb1mz25pHUvVSYEjvRg5Zi+7moPc8HgUgBzAN2Wd9MpeEp8fU9dRXQ/Guw3eFGAvjy0iSg99aQ40wXWj
# DATA BNkN4AfnOCTO2Yj00wo+IU1XvBA2TnHhdbQ0H4HmjjIaWohZPuWA3PvHV57cAC5IcuxLR5i0nXI29QatMBM5cs/M+/eKTGXJ1TxM
# DATA PNpW3aQCbvXoAh+EM0EgTUbMFGKV5rLFZy2vEaTkq2AW2hfedJP8JHUXeP8k63bT/oFzgW5xesCkP76G63al5WAXRLrbvBHyB6a/
# DATA tRlX317K98sutid2S/qX5yiGvkbdCO/yUXKa9S6bj4DEGgBerr2Mn2SHyvb96aA/eBnXTuEPteveeVjLLuDhrJdby7Qy/3kUWcqV
# DATA J5XyhVYeva76jBzulq6wMFGzruu6ix1pxCvC+JgWV210HyI65yAA/SP/vhmldfusM3AX8asUcMQaxKnMJ58EiG2k1R4nWnIcGsOs
# DATA 16uPBuezqWyhqcfpUO+6AqNr5hMCcX3/1wRAj1GER+35t+CaPqmNAxDZS4Y5UCXyw2ag7RNIiHl8Uht3mS2jtWjiaBw8OtdhHE+j
# DATA ta4bMIL0iiA5A/Dm8mJ9mXCjJSOyiAamGQaT8XAyJo8Ef7GYpyIr/TqqbQLULLqnJePB6Eqh3RAtyydaATp9oK//+DTtZknFItHu
# DATA AVirXpUKHWxJw+o9hL0iVXBvi9AkRexEh4W9KJDd5WWyzwzxp6X8p3cpV5FztZfS5Se10OUuwWrijW5EjClitXw8dudhFnIVlQ0u
# DATA hzjnshQIhnK2fOVIyRjvWlSKqvjQ5qXs47nikc+KjC2ei7VVOhe0hjVF5ZaOh8QyLHohrP6B2RyHoVhhMZ2wmi56mH/2c0+XgEiA
# DATA /yFADkdJz3tIKs28Pkq7k07arZ8OaFv4EW5HSCdGjd+p3Wmy0Qf8SI7w3iT97NSIjAyeXyelSBb4oobB3jnqLvI1rClllC/wYPqY
# DATA dlPID0vky5o6CyoQFSC84SHwp680t+EXur52NIbKagstBOFPdHHa65PuE+3ymouL5+fnjfPVxmB0vLiytLS0KAZeaED04eACCy5F
# DATA S9G9Nfh/UvviiY/YABCe6WXEgMw8j6je8gr+PgIURDZTq0ur3bUP0PDx4QMKV0LWQk+X70XLH5ysrpy9//HK2tny0gn8+/7Hy/c+
# DATA cyofrRz9v+y965Ijx3Xv+yrlkGV2a9A9KNwxzRnG8DISt0iKm0OJ4RD1oYAqNEoDoMAqoHtaY0ZQkm1thxxHO3xOHEU4zt6OHXHO
# DATA d+pCe0yKVMT2C3S/gp/krP9amVlZhUuje9A9t5RINlCoysp7rlyZ+f/VB3V5GFEsropmNEJGT57IDk3kaTLPKUhGan8b35hvxqKK
# DATA 2zvBL7xvLt9dpzY/mav2ovOtfEeP2QMQhbwWfmI24FlZ0q16jUbTq3cbXq1ZHdWrNc/v1Pfq1bbnN+rFjAlbYS+qLuZqu+7VO/Uf
# DATA +e3WqFbz97pNr+bT49XOEf19B0E3q7ViUNFg4HMe83ThAaf/W41ms9qM8ot7pujrCy9FqB3/qFHzx9W9mt/AK/e6XY6MiojnS624
# DATA 5BtqtapXa/hHfq0+8n3fa3Z+VOt2fvZuo9716j5Vn1pn5Ffbe432j2qtTjF5nX43CoKFINtNypXu0K9Vx3utKv1zhI8NulxvdIa+
# DATA T5ebTfrniD6WYt5r9aqNwbKYN1bWVLV9kSrqLZwsfKQ8wbdUDT/g+f0t1VgO9NT21rdazVavjgvG+0SP8P8OjEGzeKV261uRHzWj
# DATA 9oHysd36VrPbarebB2Jh3PpWb9Dv9PEEu53p57BVr4UHsrx/6+NX7keHSeT98G2aLnwYDMn2rNzl7WMZdYV7WZTGeFZ3aRvdju5p
# DATA H7styWTKu/RbYk16taLTuSOGgLndjEZqfvPdiNp0HFQk6NLS3EHZEQbjrNLebxwdV9riCOOA1U65Tab3a/1bNFMthlh2lNtmniqY
# DATA xQe0D704ThTumhasSjE5+QaMP/0YO4keXWB5IF8LEA9gySwSp1X1YsaNBxdteSNG0StQXWnMFlJbWUjaecad8uwt1DE2G67SUvl0
# DATA sa3/FE3941ewe486ibg/453kE94A6f0l9MW823fMFsj9T+ZRenKf9wUk6U62a91rbr6bpsHJ/iBNxjvLn7s7GtGj1rNqL9/3oxNI
# DATA L+pn0ML3sR2QYstzS++G9/Ert+wIjqMxTmcLduzdYLrDgRpWOMsZP4hOKt4gGI1QuXe9RzjwT/+VAEQmn/eU3ZdIgEj9NmX1jhWp
# DATA G9Ao2z0wVGGmq9BL56OR95q3I7HYHwYZXrZLl9QVCkqu3LIicMvD0U/RImCx/QPvUxxV7g8pVuoNFwkRj39qp5oP1UuyFSr2kX48
# DATA k8f1DwcqLwrpz1akvyLxRi2ZHMaDE42tMtmCLTZL0jLA4e7FSAYnO5g875qiiCBQ+5c7H7/yLfH8fvwKBQ2xoWgEROs+7lanM+hG
# DATA fDsoBTlMjleGKcbohcOczMc7cbibp+a9+bgXpTsc5scQ/aNf93VuFh4N1SbSHZFzQ+CiZ0Fv+vgVfL1JzTmeHOhjLnLG5ZU89vMU
# DATA 0f/hB+/sy47LH/DxEPoO9TbvdWjo/Rjh/KTiPULAn6Iw5NHAbkjy9FujiPUyPn4l4GwI9rH7D5o16QjfdHzRmijGuNQfxf0H1Kaw
# DATA 9fTDeBwl89nOzi7aOCKVRkdkVOSRonDAfSf7VWWFRAXrG7oUMJvAy+18SibY0LwzmCDhKBs8wEJ4Ywh9vHVEkX5Haa1QGNm8N46p
# DATA ICtedMTFdoce44/7UI2hv2/KxqwdVdQcEE3HaSr0I9A74tnJzi6FP8ENn6qo/iWi92M5cBEcRT+hSO7Tg28F/eGO2vzJLxqR0ZwF
# DATA IkbHvQtFCF8Rnx//RL3xL6QHjDP+u8M30Bv1cz/+iS4lyn/sjocu566EL9dPWMmS79+nUWU0D6NMRSPvEOlXep/ZJDe7q6XtUcLW
# DATA 1jdE7T432p0TqHWaZ4qVH+98jSrmfUkOdTDyGeeNPj3QUd3JH19SNlxf8D6dnG1klf68QXZQAuQuMqppartzhFiAHXzbW3r7Le/H
# DATA +/v8Oawsu8MUFFnAGZLJ8eDu1UqMRLqQRejd8mdMtpp96PNpqDeTFzbwq3x/XW17X77H/UCekbB4S3umtrPjTCgZFEfRPrfwT+Xf
# DATA YvU2C17FOp48zCs435LpYqOfTKaYh1cXoTxMZWhCQSEikAUb4ONXlu3ks6PFv0vE+KNEgItBgs/rg/yue2L5tqyK8skbu44qEyTX
# DATA yLXsl3XRvqXi8jEkPMdke0htM1FYVXNW5KeOgKo9+ivZd5NDmgzC9PHYjPfMe+liqZbp1rKiXh2YAxXLaxaqTV5vVN3R+QNz1YzQ
# DATA /E315HIDjfo0t2JjjG/R38vdvTTNt0XL1GQ/ZzLrE3PIr0kuen/zNxRrVAjqv8Y79Cd5JzmO0jco83ZMFlNDyFh8Tb+y8DRZSUg4
# DATA 12ucmKD7qgee1SCQqcVKRxfsqsGiixDvoet2p1mMTV4TOS273l/9lbejo3b7to4JIsUBmSpg8u32bZUU1F/cIst69Oa/4ChIc+OP
# DATA u5KWGzekoJSxg5VDnf38JTd38G1X7siDlfxA71jNRySlVCRliBtMIPLbrrqnNHxIWFxLOYZRxgMHlbwu0SWNkdsR2qJVKZAcU45r
# DATA G3DhIXoR4qiqKWWyDmS3WONwo7I4dnZv32Gb8eNX7plDYWgmN3Zg9n38ijQ9Sv935DvPAbm5z5J72Fa3U9u9gQT/79/vf0z/m7yp
# DATA Z8lJMmNXqxfMPJ9mLDckAD5sRgHQQ8vfQ8bTzeKt+bt8ftd//NZ6UEdog+f6Y2ncMgPMD2S6g9nuYPZ5B7PdgewX+kC2V9hurM5B
# DATA P9MHtY3njH8unAAcWce3709ZLQ8jWxwCNqJPb+e387ZiPif3bJ3nfl5ONZ4n3GI7Sjn+4nG+8yr1tOVmqBfJEA2zUtGR9S5rBU8u
# DATA BCP+VjyoXl68kibdT5C58qaTSV9HQ/mx7/xgYe2LzVSyB0oH/61n+AungzNgeoeL9haVO/RgqLxgD6WzE2wqNs9PRTcgGwZ8IlbX
# DATA KE9tuKBpIR9HnvdoXPPg1fUwB6EwP+F48C6lOEn3vR9Mowmf8x3w2X16SB3m58rqUVhD1Dqqk55sQ2AME+6mN4OxQAFNlG7Ahso7
# DATA XsnHrXUE+DwxR5usBTKyD3EuzcjwfB/HnFHhcLqbiQ7e+3Pj7vUmuMzqR/KOmH6aT2E2ZPsebCn+MWOTKhnAyUMtJoSlppoNmcsJ
# DATA SwAM5ilZEfNFNYQX87CtCcFZb856O896K9Ywp6/j9HUuaratNBCvSnfnPrawWXIQeA18mxDOMwo8T0/jbd1wid19ni1XV7DkeP2D
# DATA 7Q8siqgtOfoaFzY6IbFj2SegM1l5AXfGu6+KT1Q3wAmvR6GQJDTznOmu8ivsFePtH/tN3kSkNawp+bwhChfHAe83aqrNJNGUdx/t
# DATA S89+k+NYiqp4IUx1wLcNIqqfMvE0F0w06/utLUZTPCP0s/bS8IVXxdGqIqXvMZEyD72acIefR66GN9/xb9Wqr95MlFVYvqep7mmu
# DATA ucevqpvoQ37XTYlWnhRlq+vcVKtg9GDeDGa25BGZDfwEGxLpmN7Le4JVOtVqKEYvXTXzS9LzxEf8oimN0zPJgZsSBOZPKrdkndYO
# DATA Jb+kd6iZK3csgzPAhMzqAGxpKjYapdnPKVUQfjEG5bs0GFL/LEaj9lpb7R9jbDThls+Gohlo41TsyH3vbhh6fCZWmQWZHj5zG9J7
# DATA B2soStUTEwEz0s4hmy6OXjZKxRCnHgdvxC4Mett0Phrxj3Msw9KgHqfa+P9hFonyjojYiO5P3Ispi0ViXotI6TqPBduMo0BmCQwL
# DATA NqXRE2FeE2eYFlKSJtL5aZUrttdHEL63ejmMgb2I9TI507iDlyLh0njxrWZ7AHSGszOczzOcSwaSs5yd5bzeHH4GFCs/pLdx48hE
# DATA My8IVWvIzeaSZiMGF6PzxoqID6IZFejkUKTtitKLwgRLBhi3EiUBmSslih5i2Ugu+WexXVFKQW1ZfHVYZ/05LeSsGzvFuC4uMyNS
# DATA CQsG+5SgtxhIdFkMOxkMsP0LMn3cF2TeMDmmnz0qIRkuOa/3PWVcQNKSYneEcRf9TDLgjoHz3JKvFJ8VJ6c46M0C9mbeTTFcjcxI
# DATA Z1JkJ+0ddsoFfbJxIKR5TD1WnjKMvHs8ZZAN0Yw6DUYZbxeDpYMkHpItluleLaTCG1JvxqXEyZRTPhTChEXF4UYk0+lQ5k5ixGh/
# DATA WTImq3Gm1AUDWAUPPK0UsiadbwYn3BOvTyjKUFyVKGOdxvvK/ziIIkpWGA9Y2o9mdzDUIHCIPYzYh0DVaiZbMJhuTL+gKeIXNgG9
# DATA DxnD4zFfEAGyZcVMWTgGqSrqhBiLrjc/kUp9MkN9xibRNYn8IMqWJFDMikIVXhRUNVWdrFT2Wx5DFR6VbIQmyKNOGi0zYlGkFW1H
# DATA gvAWhDHO3slAJ3aqEpOk2vsB9F9CykSyC9n2Q/Jh583JmOAnHojHVbuUGVKG2j2Wd4o9qafSWup0EKdjXhxZNrflRH1IeSPzcTB6
# DATA pzhGSmaSUVunFmSs53zxOxP/tdxP+cHVkUwBNT0PMrGFuXfy3tXintS7MuyBTWkF4jY+ZGo8D9g8xtSADF8q6WA+i9FtBCnrdI2V
# DATA 8iSrn0qHAi6UuI3JQsB1NaVYmdrvT5JjqZ9oJdRE0EdCsFUn+M2Ew59hXyVyW9oiJWgKVwJ3jTy2iV1i+RXQ+KmUsaUhHhm4VsrT
# DATA hZSKm7KPbCTKMEkhFTkOSGNHRrCgIFvohnmKMDkpq8ma+YQtK2vZ+WIzv4DW/qefVgxDZ3YIOG96YhN0/r+zX57+8fSb0389/UIx
# DATA cr44/Zr+//nZb7zTP4BpQz98Rv/+ZhGd8z/ph8d002Pcz/Cbr89+ffqFR19+ZyA6X1Kgcpm/ArTzi7NfV7yzv6Xn6BncBnrON/Sm
# DATA rxjj8/f0gzB1vjp9fPYrHZk/0y1/FFAPYDuOpfMczGbQKeP4EnU4PfozK4hmH0YJhZPGfW2C7XtvPZyOZHwecY8YSd+QDeMp9RYj
# DATA yxuhO0esIk6j3GeQz4WS0UiNT/RSLfO7FqqD5UQVnmopDq1TnN/oHuS6wTrLSubq8Dp51TG3wqTLL5cfGInetLn7HfnOI/qWCTs8
# DATA rqlhPVGbWzGYOsDOhsW2fcQO1t4jtj5ROJXcxcjGL3IPDpksigqG6ZDGE85HltvPZpiplnYra6QmgjCHUuLZAl/n/Oq32qG5pGU9
# DATA LczO+clwnB1nCVyFJaCBO5c0AF4S5+a1Df5XMvZvNPRfdOS/noFfqudiPuQMnmevdV0FjMfKAUbxFF+9JL2LIA963XiqVhJV4VGe
# DATA pXipAt9EkjWZypuKpySwvXR4MhuOORQ5YMIZtCmCRxVZvhBJHfGI8TJzrNRCJX2G3J4p/6wckxsERwlGBcWa0THGCwRuwsMpPagt
# DATA BnWu7iC3F4RYBN8PzIjjYDKz3WL9ZOoYO46x4xg7V8nY2XRU2Wias6mVfM0m/2Us/m0Y/I6242g7jrbjaDuOtuNoO46242g7jrbj
# DATA aDuOtuNoO46242g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO46242g7jrbjaDvPEm2n1gwuS9tpD5qD/nNE21lce96IucO5q3IP
# DATA uzI9flerVVBIazZKud5odYrcnCjqDBTYCIcbKXp9DrTeYhmQPodak2BYKsNvtIoQnzpl+BI0UrvhNWpVD3Qbv9kd+Z2qV2uVqD0t
# DATA v9ns9BZJOY261/C7P/K7jWGjc1SrNcd+2/eqP/Kr9WGjfVT3i1Ho18JGr7ckEc1ONU+EX+uaRNSLAdS6tbC5SOyhjPUa7dpQ5aJF
# DATA zzEPLNBzWpeg53CNteg5VPkL9JxmoxNchp7TDKOBn9NzWrWW3w4NPaff6Q3Cbk7PabWafufq6Tmqju9xNTbjQl0IOnq4Ldy0zFFV
# DATA 53Gk0j06rnTYkiqsMTX7w4ONSTvltykHt+3aEhND3YWjBdvB7dghLuJ21ESzY4xVlPEB7+QYBmFyfKvqwbtR9XRJFgA93K4XX6Hd
# DATA 7sY0b8v6SSHXSzcV1spkOC/BcA5W7AdYHK0UJWmZp1bWbdeErLoaNbTphpLXjIaJ3/muVNVnrKb4FEr7HBuxkHl2YarE6MkLrBBH
# DATA 2XGUHUfZcZQdR9lxlB1H2XGUHUfZcZQdR9lxlJ2Xi7ITD8R+w7oHavwj+5vUndtqxFQDl/xW4bq4e/Cphel5JPmGzLjNweDUkQnm
# DATA Bj0B/M7Hr9xYfIeq1Ad6QFEvWbwxv0Ud0KC72M49UJCg93CMS1o+m/KjEz6do99ajtK+99fqDLx1KI0PnqGsqUKZKOzpG+iH19aN
# DATA +FvKCmMzm6Ty4tT+7OEsTzP1jh+/8o518s4kg7pLlQKZ6JbO+bgj6O4I+sZH0IsHwtxZdHcWffHU4Eq9zWfhjHqpjhdaiy1Ow54/
# DATA FqBFZc5ytRQlfBuHUZAV0C18IhrKliAX8UiTUXcm54S1kgpvpSudlt30DDongfUZMZazOJ+SBKVXwYU6FT2+HssuIn5LDoOqXVaL
# DATA +vXKdkUV5E9KDV4Jh+sfcz1zc4W320L+M+JwTPTizMrq1SrvxiBmaXT5XNR4t+4w3af91IJCOyxKHO5Ehyb3sbjrKkF31aVyWN9V
# DATA n1ffLcfrWeWOP62+k/tcJTPbj1bfJ/02p58/rRGVl4OmWs5d7FBbzR1DzBot90JNgP/clnXNf4G3nrs6PQ+QTzrPy3lWEttkt77p
# DATA BcSq5pqXzjk3/vO3/92koxxxK/+nLFGKPmcUTHP9VbWUyHvS0jkkEmCjJSzFMIESPGtRQ600plrIUKZgOqU6yfq61DGj9dEkdjKT
# DATA 4//QY51B/0jr0LJWNS9+aJHZY6rc6rC48nnZLTM/+aybRn6w2jjOcFklxeSMPnpJF9gXzDWF7rVAAGXV1gsVUV5RL1pAf/e/VheQ
# DATA rvRSPG+jGKgiZ7qAPjxOqI2m1LF5+pRfpkwQ6pPmE3giaUia7ntv0ygPI2ecHIkgBaWBBQcgbHAYcbeKApL9w6qcIq1uoUrryUvF
# DATA pODaysV0Cxctln/8n6uLRXUxUioiB9pPUpqMmJYzURNhuczTnB5rurKusnzypgEaViimgyj4DqgPT45VERXtSJZmZ7O4MA5al+MZ
# DATA jOgnLyU7RddWUHm/fOEe7jerS0r38VJUHwXp2OPdXXkXd4xrAscJj6CFTSVzSAXD6xfo6yIZ7iehSGlErB4LneloAgiOlICaDfQi
# DATA JnfEM9HkwO5Y+2emTjx5+eTJuLbSeZIR6P/+w+Yj0BsYZKNUhgRLB3zMdjXFK32gLG1uUsGI1csDbzyn8WcUpNgnN4V8MjLa+5EY
# DATA j2qAIRMJDANpNijxJy+JQnSfh6byT5s2lfvJYOb1UO0DlE7erWGM71EWjaFlA82YPo08mBywInQQ/jTA/hxV4zMUVsr2eDyORzhv
# DATA gJyCSgVZ6p/MY1GrgQoiC6tIAWpF6C00lUIyLlVARSNQPJq2EWiuSHbfeS/RvketKcSzD+UTTFKhMmKATrgT1wWrhH+ehB30coi7
# DATA ODi3c6VdwpXmPGcviefsorzuZ0LdsbD/cj22W+bcNJDOsFWTLMpDdmqtJHc/oyqQz5Fo2nna0Pa+x6ugeC+2kq2zvJfKiK4iei+m
# DATA XN1m1LHF+YJJ0L7nG0lsdiZVxHckapDHiXFc5E4mRe1TDuExoNxG5i8v6Io3zwRfCllACgY7IyQJWVkLe0mtUfrcXCdzPc1LaYG/
# DATA B0/X5BDQQAGMi26PkQK3lAU1+EZpZt0ycqIwq3NRUVtJ1GOfCVmsMyktzHtgfXvYiAu9zaNCfZDNbJJZvF0VmqiTvMGLdqHOLeTw
# DATA /stkPNpBOPPRmY8bm492XXPrsG4d9gmtxpVG6tWsw74r3E9bKTonHj4dUsV1UMJ57w+qFx8bLCxzqp9yvLa6dWG9MF9IypfHVq0t
# DATA 2ssb9mrNqvtLjvbSUsKqpwru34JPe9UTZTdl2c266rmy96zsFVy5clooBd5khZiiOoVxyPVBFppee1XLV6piUfeCXy57ToUlrs6Z
# DATA atJ5eREch8w1f8+2qDzNvadO3bapxGWmX70BRZw3FYxPCg3o+UWIY6FpxiTUKXr6TFmqych+SzTV44nMONkEj/RMykAkqf2Y1ao5
# DATA mwoUGj2D597UHQn6Fnt49pRACE8AjMmunvoIlrj0PbLuGIprmfeVU0wg3I0FGvXEzWSx4PJ543KncV7X8r2F4HjqPopKulTC5zPA
# DATA Xxwr2YIDshRSMi6wAf+7gvh9c/o1/fun08fA8D328I2xfN+A9ff16ReA8i3SAf/X6Z+Z+Pd7dffj0y89BgX+7vSrs//j9I+nn5/9
# DATA gp79SgX6pUIIfnn2S1yj3745+8yjLyASCggQZELEQZ4DsJC5gX92MMDnweov9N2D6JhsB55ETwNI1yoIAHr18QDyET1IdmkMCHV8
# DATA WJW9q7C6SY+ZB6p77ulOS/fZ8ym/Bk2IwyMjoy/+k2g2n65FAN6F1IUXzjNsdqH27ACABXtf9xLXzf9bLJaro/+xhcWElfzWQn0r
# DATA 88xvRifRNI7I2tD3v6UueFAZAkI7SbeMAWT1MEZCz2c8/qszWtTEHAlw0yLcPgqQ+hosglObn8QDdDoMg2eIM7bLpclDaOhEfHZZ
# DATA THkYrKiF1Ln1Z9jCMGfpf/kxU5tP9N4TXdHEpUqWODNuMI2LDycLWMDNq+VqW2eh4T0tOODmiXGQQGchbM9C0GjASxkGL4cT8NqM
# DATA giuwCTYyCS5sEVyvQSBVtJwdxgx4ZlrVVSABrVSr5a8VUdRwMXZfPDjxDtMgnAcK+pflqw+QMSyusTFqsLgocSKbPrE0f8SuJ6y1
# DATA sSxiNo36GPmNKbYRHNCM66zMTQnOZB8dZeAA+DKugHvJYA+Vk/tZqkP7HlRscXw2EMsBPjom4Kk4KLYakj9N6VLGa6mqtJX5JouE
# DATA HFm+0WTfvvdeBICcXJBNe/fnMEPSZH449OYTKqaZnGHnF2cOI+gwgg4jeIUYwY2HoY0mSRc1qK91jnCZKcI2ZwiOKuiogo4q6KiC
# DATA jiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCjiroqIKOKuiogo4q6KiCzwxVMGpH4cC/JFXQ79Si
# DATA RvAcUQXLK9AbMQWL8Lxuw4LntasGntcu5mvYjxrhYAl9r1Wz6XuNnL7X6q7M27xgxn6149X8tuf7Da/T9rrNPb9Z8/yGT+VFV2tt
# DATA r9MpYfnarW6n11mG5StEmfdhLsaXXmghD/22iW+zCJisRq1+e8nztVotf75ezZGJnc2er8srVX41a3l+bfZ8o2nFv27l94bvb3Ys
# DATA 5GOj3r7o+/2WXd5+Hv/6hvG364uULT/e2OzxVttOvg173DD75RGV/Fb3ou8v5l51g9dfBBIpjURDIqUvsyCR/XYQtv0iJNI8YiCR
# DATA tWq91+wWIJG1XqPdauaQyH41rIYDA4ls9FudTiOHRA78sNUZXDkkcoL+fC97cJKvc8gRyqNoC+sONcvVoW0uth/Ma7VFWDB95GU0
# DATA m8G0fskeFpXhdjD70C4q2vdWKPad2srZjFhZiKhe9FBcRClBfY/Kkkeb5tp+y6Iaena2qNs8vaulmDd61op98gVHawnouGaHgtqP
# DATA IOnYy+iHcXQLoperKY0mHyql5K4x/cqFXFlbXuxMMUUm9uBCNRHzqbZJTnEIjgLpKJCOAukokI4C6SiQjgLpKJCOAukokI4C6SiQ
# DATA LxkFchHiOA4Ob8PUo14dZ8woyTflqz7JgkxQyMV3bUUBtKob9DTVhXvYELnj7974+JX/+O0+Ew/vLtUZ4Gd2JPxgKocN8EYKZteE
# DATA U0M4//tzCecNtHg+vjQOJvNBwDr9cqpLziNSc57K0TccqgoEuRA9pBv58CeZAxkNbQVCYuGMjjt9707fn3P6fskRLncW353Ff5Kz
# DATA +Cv1OK/0jL4oIiZ8EDk/7i3DymtGn/Ppy8dch1anjHaQUTVRGPABWWV17ozHu4qSqFvohB0guaCfDsJ0a+aCUbRsN4tKkuN4Iute
# DATA VaU6yatASm8S+23419U8RTMo21XlovG2AjFRt6+Z2NeayyJfs6LeKUS8ut9cHXUz3ttR1xdVPdoJo8M0oqn6OSmwwjIpsK+ZFLSW
# DATA Zn/dzn2/tibzVyp06laCGi0dxPOqzmmNuMxDpDtTac36iHvB7MO8aba8ydCrYhxZ753kjdy+gUX2RT5fijvKZtKVyJOCZzRVIg+D
# DATA b+6dCMqx0C9p3QHWr9ChUT9CRqAyEDHfm4rZEMaY+/Fj0BBmSY3j4EQGHilOHvszLaxxOA9oxJlFEUuDK2GLT6iDI/MLR+uVKMiS
# DATA GG0g4PniHVgvjYrOsnaW9TmWdclocla1s6oLVvVqttKzpHxVbAWByS8jfvVD8PeM2hFWsXOtI9aTgUu8YvSbBF0cjeNsyhI03oeG
# DATA rsLGO+vmRPDMHUdMZq14es8GRqVoimX8lB5B/Slb1EWC44LYlbmPhv57sZI+GiZp/LPESN4oBf/Ay4IB+DpRSkYRSzCZUsmmSa6Q
# DATA zhJFLBqlZhFRkJ3wyDtMxhFEeXg2QXZfRTgZIsWDe2m0poE1hgnBnVVGuYVVBKUGjq0KK6YMBdsmjHTc34EwT7EDxNYJpdoDHmTe
# DATA IRqbaD4J2LCherXvvR5PEtQhekZjdrUhMIkeztiQ5CUVZJDqR5MMbivVwyoTSKrAmF9mgUKXGRNL0/Z9G4wwSg51Cj/AiWYpN6lW
# DATA hTlbjAVZqH/EuViR4S6IhNfoRKnlc4+fPZCalo8belOkyL9mrP86gFQ7J0IrkjL0lHFhHp8FA24b2TvL1iXqfZHzklYRnSjJLIzU
# DATA 0zF3YZJGUQUT+dleXh7sAMyN02BmBMPy8YjygiospVEmnEpPibIMu1xH2F/CVRlHaFK7Qp9k8I1zbB5SADMyDuMQNNh9782EmySG
# DATA P6NMBhE4ZTAO0PmlVmwWCEhsWZ2r+2ri0gtUYc8tBX2znmKYpOaKDBInckGL7KvJWfF5/rE49dKLU4VpVZWnQKo/y/syJhZIzc2h
# DATA 9kpm/4ne5xvyxCg4UejwoqmSUU+43XfWeAhlXE8Yj6X/2e4bsE3xznt67ECaptGkH4+2+xbew/2WbkF6Cc3uQbf7vqYALAaR2TNE
# DATA DY9tyQm1tuK7bs5HV8agffHmV45E66ZWm0sGu4nUCz+Ruih69tmSEDZ7eq+CYVrO7K0TTJcoHZ/PLx0VCAqiAcxuyKKu8Bq87rOl
# DATA o/w8SohuiFvwChvLtRGey61KvpjJxv7C5Dif9la8Qyg053MazMK8ABNgbLUy89A+TYFt/VhRbcWkKZuVZqW5N6HkSdD2twjoFmot
# DATA WS9H0flC0qiT42CqQQ4blcGSEn0/jdijXlDDzqIs06zCl8h0ywlXveBBlBbwVv9y+gWoU2efnX6tGFR/ZMzV52f/jXFV/+6d/R0w
# DATA U6e/W4Rb/TNoVQykAsfqs7N/9E5/f/br0z+ffnH2Kwr0ccU7/Te65U/0/Rf47p1+Y0IDNWs18OoX4FrRfx3T6nkg2VIdxvNwNlAF
# DATA YwnsgHHPMkSQtRXzSBDCNQG5ctU5YU4mLo0JOy24XxooME8olxL0cbK/Vhh51HNk7Olai7B6HRto0U4idBYOYGUboNIJXDe9qlwi
# DATA V8eugiR0WHrvUmQVVzFz45tc4a4GVkWj3lRt+kUtxSbhJAxOeB8h1Y8HkQNWnVduW+dUvY5mwCUwjVKcFWXFehzHGzBgW05femS7
# DATA Q8tErYJYW/D0ej/E8g/TKIwjeKPBKKA+NUrh7cqXU1S/GE/IHJpLDnvjeSb9mZhhJ0L17sfTaIFitUlNXW3PlJre06JXbZIIx61y
# DATA VsClrQCNqbrE4P9SeJ6uaeDf+ri/0bC/6ah/XYO+VMZi6s0g/7Qay1XQp4pJ9IbRaArrhAwPIJhN5PIEp8OT2XCMFVlJ+i0ZaiH0
# DATA jhMuM/4AtDSyRVZHqcMEzehtMvCDIxonM50dqUib8dYDrMmmc9ZSpPiPY8MFWs+eUrsj4GGKsEQd8ZkuGYg59isGc3FxWAYB44l4
# DATA LMjEhNhD+w8L5gXvA9SbKBQKiF/CAgpATdE/2FMBO0+vkc9nCeSh+kzqcoApB5hygKmrA0ydN45sNJfZ3NS9Rqv9Mkb7dmx2R5Jy
# DATA JClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkKUeSciQpR5JyJClHknIkqWeGJNWqN1q1
# DATA 9iVJUoPBoBn2nyOSVHHleSOOlJ0ptZZXb3c+2Wvs+Z2O5zcbe7Vqjf76nk//NLoefS3mUD/q9OrNRR5Ut+3VQH2qe361M97za/RP
# DATA Q30tgaAok6v93jIQlN+VgCn9MQ3cGn1Ut9BL9WbLKnrFQRIoURFcFTWCqBktRLTR9r1ah5Ld9Px6bVzv7PmNpvq2EM+o1xssjWd9
# DATA sX5Vm16j2Ry2qv67fqPmNTr+sKn14iwGVrNRi5YFuVhjWw2Kad3/Ubcxrnq15h7943fGNXoNFUsHn/dqHfqy+EPppZ1Oq17rr3np
# DATA RVBH0kI06kgam4U66lXbfi0soo4G/D8bdURfg0G1gDoa+OGg5+eoo3aPsiowqKMw6De7zRx11Gk0q37zylFHvMNkj00PmyWkIluc
# DATA ffoYCT35LzVzezJgM41kZrAO8sMjV/7mDehDBSdcyzjhZOltEVBkhb3okOcRVrbN0UPRg03hRNrSqJUD8C4wXq95bP3gvRJCZJWg
# DATA 7Qv0xIRenZ5S4bZRqm1VtMX8WZ0cRxJyJCFHEnIkIUcSciQhRxJyJCFHEnIkIUcSciShl54kNFAcIT56RQmuHN8efEcuDU9CWT0E
# DATA 7IeMm0pmfsoCtij56om5ehJRj6wua/rQPYTLBKHBDcqhQ+YDfUQxlIvHRRCR+v0+Bc8/Z0t/fnsCUSQYC/Q+vu9k6X0fJrNgJOf7
# DATA +K53g9lwn/0GO4MbxzeyGyfqZpszlJ9kcUel3VHp4lFp61yTOzDtDkyvlvJ7Bg5S40zqIK/mwYkX4PeCvPmMlU+kPqMEjEQ46k0F
# DATA P0M2bzRKjtef9R3HD/n48TRNkoE+fwydcdNQafzFVpR5GmVPoG1OI2J6gqTMKEuQPn3c8q6XzafoVKNQteg4M+QjsmwU2CilAQ+1
# DATA E3J6o3iGRZyEJg8ZK2ELyKSfzse9A2jDxBM+j52ZQ9UDOHuP+PzuR3DhFhRMUtZ0FwXtrJ8k/ER/PoXMtpxrXqeg/QZsiPRE9tF5
# DATA PETlSRtAZB0qgAiSS3USRWGmuzNJbzZLxVymchwmo5DPuiLmlFiaA7McOEplgN8OKcqjExYKN9lmyk6UdVgmHafStSo6pwETuVEy
# DATA Q9LpUi85HnnBKEv4YPBaifB7VL256cixbXprlFqFx4LNPbY2Obv0zXGmT9Efoy6ie2ZxnxHO96If3/dYUT3vyfvYkBJBHj0e8clc
# DATA nI3P9r03WK2Z666nATWoDhR5hIrUBiE2AnFY5hiiUvUPZueJunPOcZyPaSAxuoLYjorz7x6O0uBl1HSCMb+OBjouHSUJ35/PpHCx
# DATA rWaqTgOLTrw5740ro1hRuFAtfgaZeobjZEbR/IGEJ/4VDpFMw5GdJbE5zx2k48vpmr8uQtTIOmr8FxY2RyPctrL5B8h8FN4Azmnp
# DATA na5A0DxnW4rgEYqCDVEv1yO4Ak1zo8zIRs1EtT10sxjzrkDi/C53+8ZWUmoS16cE/uIc5M4DcTMKN6MozijKVcpNK9y0YuPpw8rp
# DATA x9VNK+4jK3IcjkRHTymeeW3A60CUiiONLrPny9s5PA+LqR8wHZa5kNM5qpcBklZXYz1z1x7d8j39xdv59nmRtR80ES5czCmenWVx
# DATA bjStKHc3Jaiyv5EJJaPZBrFUt+eIV/W9YFItRM3OzHqRkLomauL0pJ8LXskNIqkfNLE0F3K7dr99XkRr6yK6EoQq81eMVlZLe35p
# DATA qNLU4qwodmQ0S+9R30Ktwzs0c/GK1+p82zP11huTSZ159Ya65xj+aZrl00Q6OkzRUfJTGpmF6bdws/hG7o74q9Jhk5mpgZzGrFYb
# DATA 901XhzdGD2XNRE8ZsAyGST3CKkmZsTyX1ZdpAdtMWGXytKxCYNKfT0skdur0QaRV0DagnL44trej7zjbe7033xnaL6ShfVHKzlMW
# DATA QuUdwPkG2UUD1IbQsOhgoD3YRi9UkrCaQvNU5VOfC1lB/u+WmUYloddtE40WpHKX8ow2EK+19lHnErb4FkG4MgkGFUPQYStrng2V
# DATA gVWqp9gpLiWrdou/OqzfuZfGWLfBLkX2ItIlMOrjh7Bh2Psv57mYdhgXzR2aQGIWGC1bdlGqmiJkKvqk6iADb+FSJk/RgKFpqeVR
# DATA NVaLia4d7/tYs0LMyb4rxVxkd82iCsWO1y9MmxCNUb0soxikOE6G7dnWahHLp/LSE84irokwmv2GseVjbZOE6b8c3/tYCVILdHr6
# DATA HBXFUYPiwh4vmYzMqh/FUcEnsQKBRbDVEaWXLcvXl0a70yIHkeHWB4fHYgf90+kXp1+dfnP289PHgP6c/vHs1wz1AT3o58zw+Yx+
# DATA A13oN4vwoIWHT78++zVwQz8//fPZZ6efn/6efvwVM4i+rHj06YvTL/foiccI2uN7vqF76B2CFloJE6LQ8ZbP6Q10owMKPfsW9Q+h
# DATA X8brxNybKFrYSUUWBHFJOlq1OzWNDsFf1nLOsvCv6qsZ3FMWbS5Qpqk3XssQemMYiKqBJRnuOEKWda26hOsmCS0rl6ujCfGGgGEy
# DATA NTd+pC4sZwoN4rybvhfPjCd4yzQhgRqzvSC+Iovo87JzhDYpsa3ThO56Al4HCHxvNu9FpuTFgx9jD+3Yk53g+967CdWAiQEhUiEe
# DATA Qe8dkh5YI2AND5hlgdrsEuDzSDZ9pHAfjpnHKM46Nr4E1giR2DI8aH2VXG3ELGlnTwsdtD4JDhrkRvqLjPSaE3TJAf7lcJ1d1+B+
# DATA JWP7RkP7xUb2qx/YpVou5kC+0fX6WstVgILylEFEiwLIFuM8g8cNmzX15j8d37lJOx9yYpyILkAQYGL+nfkmWAJj2oraEspvGQcT
# DATA Sl1m0i2pNcELZmg8pS5sMtsIGwT7aoaD/MgHCmmQUm+XD/qxLPfrhS0Ew2JyDDEyBKA0kqwySOQTASpXrJE+AeYnGQi6GC+iiujd
# DATA nyHZMXs84oFHreqB0FCOqaPAnkG0Qd5gkCLvtEPU0YMcPcjRg66QHrTZmLIh1Px8m/eajffL2O5Paro7dpBjBzl2kGMHOXaQYwc5
# DATA dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHPTPsoKg6qA5ql2QH+Z16v1l9jthB
# DATA i+vOG/GDDk2SeRdhkTUTNqNwUF3Fmrnzaj9OYf8L2KcmCVFgnzaLNLC8ge8rwlDh9la1cc7tFueHwvboHo9+2/O79LdK/3ab36Pr
# DATA I79bpWstr+Y36Fprr93dqzVqw0b33RqARe3OsN0Y+/XmXqM5bC2LSaO2KuIKYHTzsFCBGjUfkaE3jPd8r3okiJ412RgNet3WckRS
# DATA daF6Upybteqw1ai+i1Q3us2jRnXcqDb2GlX6VEYQdYN2r7Us6NrFaUBS5zUNSJqPRQOiZPTb9SINyG/XO42uTQOqVRudZligAdU6
# DATA zXoryGlAvUHYCENDA2rW271OlNOABoP+oNO/ahqQMkqWOz50Wku2lhqJsHFtb70V4tHNGHbye8vgHzNRWjYp0m40zHUrjf0G839q
# DATA zP9ZXI9qFSOljRurmxbbhRNCOR6ke4eYGoNnUQ2jw4q19m5/9mrd6cPKt+rVZrvVY7ffbmV1SN0LBqWjnE2j/kWpRNrmhfdwwaSy
# DATA VuRWL46rpXDxCe9l9MM4uhUG6YPV7KE8hyt21FfbHCWzV+oQ206OJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiTkSEIvLUlIkX4+
# DATA tI515ee5i+e4yhge4QbJKW/KI00Xwo4ANCPQefrjfYb5vJGMWQB94ZA3H2/DUpKoVQU4qJJM1PE1LUhbPCgmbVQmcvqkhTvj7M44
# DATA F47auKPO7qjzJY86rxQfvJoj0Pdi1rrgs7TsgiyfntVHoZ81uY3r0ONWgwuqDtVXJRmOVO70x+dJNJtnTYeVXzEizZ2l2txNW6TZ
# DATA 96tFmebmGqlrHvwg6aJ6L77wqtiyRkVZ7skFrvVDrybcmdoS0i1e7vmA+j6FF+J68urNRIkELnmixdlFY4t305ul0QPWijz3sSa/
# DATA yDYDxjBoWD65+OxNSc0GQtVv6fqJKuuhyj6/KtXvRkE2h2g0Dtb2gzQXqL4/E0k+6kmSZCY3yLFmyPoEhxB7hj/qmMasfe+HPLiN
# DATA oiOqNOgA0amOVdjcjBWcJkmN8FCakDm5733ACwBiGskDrLeohP1oODlBQVNBxLOCfDVgWoVj+3KO1EvnOOONI9cBDthDw9GM59AP
# DATA JIuN6iwXfkazs3k2jUT/kBWzg8l8gIE4xVxKAgQXKYwHA1yZ91hPPcY4TYExdmeZradECCgJs40Frl+Uc75O3tqZr5b56uzVl8Je
# DATA vai29VOW7OF17XwBdr229V0ajdhoZAOS7dgsl6JgjkK2RuP6usV+ngu9i6uQtV6s11uXtl6q6XRZeet80V+bY2JRKNsnAlmU61wu
# DATA as3mzwmZNALU5KUget2+97roBtEsScRqomACE+UjiAiJ3EuGwY0xo0Jw5OoGM4qsrlgLP5MNl5DNQ0bdA3qDJoZcrOL8QAuxGFUn
# DATA 4w5/uRRPCjnjjCFnDJX6VOfNc968Yt+50op6yoKGzAMGuDgZjURnvwzsVu0kyHIJv33vnnC62UpaJs9X0PKbpkk/CkHjFim6JP1k
# DATA Hokv50n43HdjA3U2NN4ZjaCaCTiOZ4KalpHUYy0XjsGcG/lhMD+kUfMDGoY1LbDCAYhZIss9Cu+ADiMYDOAUY1dJ7vI04/TbE4z3
# DATA M+HXzhUtIhr3ohAiaGHUS2lEFioyD6EsAogdSmtR1jL65/KMggMOqCrAD8qagso0yLR1AeU4+GtScZYq8WmyAcJR1AvSfe8d2E+I
# DATA JlVSytxAgcDCAB0MkAi9kQivDVkYb5mQIX/MLNVCcclmoF5/QgUfD6DzNo6w9hf318LIh6xqzZVnMoMHh73IJskfAcqRDAbeIQ1Z
# DATA OomyT9IbzSlT+wEUG7keA68eHAcn4pjS8VRlmGm3DmcfjwMUjIo55UsmCtzwL7EK94GSNYQUZsonC1TFNdW5ANaYof4wb8TrUQSi
# DATA lV5nlWoeaWRsgUw488FzoWoITpmWRWZMQomPQSZh+ad4RD9XtB+KE5DDdvpBmp6wcuNdyrOA/XYqICHMCzxOc3yOApbkyzPpvSjm
# DATA VImfWKlfwiV3mCSh5W6XtybU0Gg0HEhbKxbh5WDfaMsnrPpIfcxrF4Z9I27bhn2LXR5LA1f6hfEE4PgovALo9+tg3iu5ULV15AoY
# DATA 3x+VVEiv5E0M934HTUP6GBrXZFtOJsSc7b6NTwF9ZCiJWCGaBnHqPYC3OFhM3VUSxV+MqY4Fl0mCNDyEb93Gy/wPhZH5hqEuoMN8
# DATA 4Z0+Pv3D2Wdnv17kyfwL3ffH098J8oXvYvILqDDfnP6JPn7OLJnHFc/wZR6ffnX6OXA1j/HTnn7qsUdfP9dB0W30wl+c/VLBZSge
# DATA Z3/nMWPmd2DTgELjoDLPAaZxopldC764aZQAAa1G7pkITL+h52vi9zjkbdsY5BQ0jLV7WV44J3eZgY+ip4fC+SRcS5m5y7fkb3aM
# DATA mcJszvQM102ZWSyXq2PMcALNXd+FkDjl9WhQvi+E9rMBemG/7ywNTraJlqE2kJGNnYqAOc00YI3xTAwF4eAy64tq61QZ0wmFMZnx
# DATA fGJPTB0yX/EURO7jhx7XC+8D3h4gbttD7I9ctqlc2IfQaNdK3yizSTRjTXPs/aAxPFtgyKyreavtlIU29LT4Meui7+gxbkh/oiFd
# DATA 42QuNZK/HD7Z6xvFr2AQ32gM33AIv+oRXOpiOdn5tsmn2GKuAilTTmhOljGaE3nMKTejQCFm4H5juQF4uiZUpJms1iIZhp8hwyrQ
# DATA E0dxyrgYFJbGylDKgwwXcWTcEIWxGioD6wUgMiewtti3KyEeyjYzTBPoY28kHrfDNOLzAJLtequb8q3T6A8pBP5+Lo/kAOM/Z0lq
# DATA 2QxFzEiUOliMg8U4WMwVwmLOGTM2Q8Kfa9leq3l+KU71Exnnjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4
# DATA MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MM8MH6bVbvQa1UvyYQaDQS0cPEd8mPKa80Z0GDtb6lXPb7aH9Xb9qNZtfI++
# DATA F3Ok1263G+FidjZrnt+pUoa2j2qN1vfoe/E5qpudnuKycFlKWUnBnQiHpVbQlWh0i2XcaJQi0ou67XKAtVr9sgGG1W6t3VoIsFPb
# DATA bgzrDX+7MWxI1dleDO1CobLcQh5ahXLBAFeUslUoW4mhXShbiaFdKFuJoV0odQl8ey3lggGe31K2EkO7ULYSQ7tQthLDQqE0G9tt
# DATA KRcM8PyWspUYFgplGzEsFMo2YtisWW25Wyxlv14KUV1IVe6XB/9WVC+huFrdRtBYCktbBh1rNusWdEzCTw0SzDJSdKgL/LRa88kC
# DATA aHa6VgDN7sUDKCSh23rCJGwWwEV4ZmKjaZ6ZmHsWzyxotBr1qMgzG/D/bJ4Zfe1GgwLPLOqEQS/MeWbtXqvVbBmeWdjq+0En55l1
# DATA +o2gduU8M+X1UBsazExInPFkS7KDwvJe6EVqMz/r8ErlkkX/Yshljtl3IzJi46AiMSntRVkSnO2I5EWeYuhq3ff8aJjpy/Jdcvp2
# DATA mhwfRpstFTU3WZy2Qi2vOts+E11Him7nmkzkF1YP/bq1SKzu9WtFL4yurrzHchiEyTEvxGDFrerpOmflbZcdFjwrNrO5Ffvp9CRW
# DATA 5XZ1NQPNztNzPBpWbpXqJE+Waw6E5kBoDoTmQGgOhOZAaA6E5kBoDoTmQGgOhOZAaC83CO2Rqt0xFdxthTLDZ0p0hZOkLuLoHjJC
# DATA bhfVzdvUsVGd2UHVim9XD+JX+YmD+MaN3Ue4yLcdxIOd43hC1hXZYSfTWfIajPgPAMUY/4jD2X2kW9D0NoPWGASy06h1G91Wu9Zt
# DATA 3eQo7X6H/6go9G7DBvwhzd7rNel4/d2DMHkk7yi/Yqe3e/Apy2bu9H5c/cmd2/Su3QORfMOFb3PQN/yDTyMy1pUWnBUX4b9xgDsq
# DATA Hrt0t1Ifnc5p1FPd3qcSPVSO2+rnnybxZId7K8pB8OHQGG6oH2WBdmcnqPSoOIIbvQpZj7klr1I7im+vtGZHMQpmFNsV8rY0Dyo3
# DATA epOkjWaOeC3b+DIjwAFytPspthJMwp1RvHsgeVT8nVelaeKuuuI7fnW3eAOGYBWfN3Dvvpyepsr2qUbWmaOfTlnFKassKquYw8BO
# DATA XcWpq1xQXWWlKPYVqK58ADkurQAySljvgzW7jPDK0xXyug46HZsCdFU8QV4y4MScg6VTD+U9kvpeUJNdINL5FpCuZePo/DUwOjZf
# DATA UPXxAfMPFEUJRqfuyWF0+qEFRlxLgnooJtJqlhyPSW/Bu37enb6oAZMFet6NrLD74XE0ok70nHtrVXXvhEzg0r2bo+u4eqOVc4k+
# DATA t9S672tGg4xHGVkPUWik9oy8DhlZRhZHzPey1A6T5DaT7WERGy9L5ilYvgPBqUB/W6xGaDjkfDrxWpCROFEyPpTEE08dujdiMfTO
# DATA BbWYYf2Orf9DaapTwYx0obBFZuemtVFXlcBoI9rci6AYko8lzuh0Ruei0ZlbF87qdFZndq49+dS0/u4zaogjyS5uIEdR/Y3RaYBk
# DATA 47ifJpYE3pwtVKV/F1DrmvRBt1jUvjODYt6i1GCoISUsJddPxuMo7cd6DGTLNY2w0oKNCxtr/3HKpnfui7eqdwKfWYRdJhhGDUBJ
# DATA 2L80mGIvxRL9LXXebdFEVe5Z1ET+pIxTZXPoH3MDyFzhg89Ap0UcjoqfLDeI4KCO/FLb0/h8wQlSn4uWp3WH6SjtpxYMOzhN0RbA
# DATA mpL74nV2oDbO32QDbtVd/QTEDWouR3zzG/nX1c9wJcLd7+PDGutSBmZt4YkL1TZJMEisMe8KJYw9H9Kg1dHOHOlAnZJhd7DHWlZ3
# DATA VF7aeVHCAfFuGNPOxRnMtSmd8+21//zs/2yZVJSjrXJWmWJKqpIqSDo7EWOM7DsemcDk0ZYkD0I07duD3RXyfNG7G4aQxqOnhQXU
# DATA R2Oj2s8TReYng72CB9n8k9GRiSiamAzblN6y770eTHIq4CSUSan8dA9EGLykXqVB1lCC9LGTS+VrqfZcInsbq7O3UBcll2Eviw1P
# DATA CZkFI53Pd5knQ4PEtCK5pifWnGsBNgHM4nFkQ9mmoznPnml+OReLnglIyqPv3Y3HyKsBWWvZELAqNr1xya/h6zTJ2ETf994CfBGv
# DATA CeOsP89QQBySLEpuI5dNe7to/q7OW9Vyda6ix6eud4YPOk/fxN6ewKv/x2/rYCWFlCdYPJiAZ34MfBDVrTnlHZWFTPEzz6cC7cJp
# DATA Iesv/YjmIPve+9Rl09T7rlRsqb4gQDEnic8renBvHHiv23fgDKG4S3gmrTZ57Xvfo68RV2Qq/61V5Etn8foeopDNH9FAS5MMCiLV
# DATA eWzM2QE1/D3Rc8pZYNAOpPqFyjSVPJQVn0z6ArkblRR+mkChxzEhlAffg3YpTgZmrFsamECCiYZSVeRl9BuWUCRunOmHsUiegkd2
# DATA FCfUQtTDgfQ8z0bn0bpQ5/Ff5zGvfOrBWxeCZDDVXxrjULG5ArINpA0jmQ4h271sFE8pP7lxcN8C0BlPb3qsb6o9glBQxaguSqzc
# DATA NXmH0UyKjrMQC4lZMo5w4XAecceBp+OJTFSoX5ptpfu4+sHvDR6XwESKTdU23aK4NWbHiXTIkrXojTNBaIpQchSnNLodIxRdj1nG
# DATA NjYKvzRdR9NPVcsnW5BVnfFO6ppwWpF66yM1uaOw8cQ4wUIuzx3QUzB2QroX2KzlzC2aK7JsbJsr5opk1h1qYGqBVwsJy/gtpqJl
# DATA vlJzG3LDk0LZP4/19CK4XPLZlnO5OJfLEoKC87K8+F6WlQ6UZ4qoUDgqsDhSjmzWgjeKZzjizEoojMQExVKNJuyCyR/k8yScsU8b
# DATA wfAsa5Wfx0+yDn7IqiQffbnzKnWk5famj74Xjtd15CyfdS5fLgQj6Q7LOImFI+nSfvsJaoe87WTS11FRKo+5380Ws+fyWALmsJ7j
# DATA L5wetRIzrN25zza5qSKAIAeTE7Nq9b3kGDjkE1V3XvP4whzeKbKqXvPeoPsj6kxhDMEIyS3h1zAJi8dc4SbZscweZtho5/HSMevv
# DATA x4roqtlUgNEGZJuBjwvtMjK8esnDaIEXVawt92IGZrIDkrJj3p9RIqXYX4YlJ5tzmTCP26Zc/jNjKf8VyMmz33ggUp7+/vTL088X
# DATA CZelO/+cAy9xf8U7+zlde0z//eb0S+/sV2e/OP0CT+Dex7j9K0Fg0u3fnP7+7B8Ar/Tow2d025/kVsexfA5MNi9jv3+qDiCavh6J
# DATA 5sk59wT7nuyW97K5TFhlQz5za+VBbsAYM3gwYY/ARKZRA0xYucHBT4alhSFvnl9DsXxdZMAEleEQlkUTThr9dQMsS0VydfRK2AFH
# DATA VnevKh5T0OWn8hOqCponPlBVElVwAo/YVoGWvFtiGGTsrwH6RznKlQXjoJabluDW8ZZ3YZceiq1i2NEV7jZDONg0IMj0WWJovxkP
# DATA BnEfG/KxbVl23ESaAa5vnUQUBv2cirt/gWi5UR1cbZYUW9fT4lpulAgHuHRj/ROM9RpvefEh/iXx0FzT8L7t0X2jwf3CY/u1De1S
# DATA LQvZkGMun1q7uQrIZSGNmJIHxYRhW6kkAMGOpzMZCqcpuh5w6oZBL+aFv1mmS42eODzEAssDqgaZzOOpHqtlbky3ZWQ2I/AopgqJ
# DATA 5S8h/GVQ/Es3RVwiGw0TENMGiv+IunqcYcMaiEI76tjzttcFrKSqSXsFY0EWhDiWLJGCUJCHyACsfGZ70yjdY6uOSmA+5l72wDIT
# DATA cCOivEcG20qzwTEwHQPTMTCvhIG58QCz0UzmAvbw9Zn2l7Hst2TYOzimg2M6OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6
# DATA OKaDYzo4poNjOjimg2M6OKaDYzo4poNjOjimg2M6OKaDYz4zcMxaqx4xc+uScMxu1H2O4JiFleeNyJgW6s1v5pTFepEq1i5leF1+
# DATA lxwvIssanVa1vSTDgd1s1YaNxniv0fD8zlBQZxZ4rEwjy8Fj9QXoW9WKawmpthDXamtVXHu9VqcZLMS1VqO4dlrbimvXimu7szau
# DATA Cma3NK6NXod/Lca17le9GtXf7cS13tlKHWj3O63AX4hro7rNOtBob6UOhO0gbC3W10Z3m3Wg2dpKHWi3Or12byGuzc6T1wErOAqt
# DATA 0WoPW/Xqkd/6XqeEx6UOtd+8HMSO+lINsZNu2YLYNVrUbXQ2gNiFg2YRYteIGmE1h9g1261mu2kgdv1OP+r1c4hdvdvstGtXDrHD
# DATA Hqo9Wd3Qo2vD4tdZtLoO25z5/Rfj0pWdrvV8qbUlTlcOmc+pbOZLba3zpeo5YR7o4qqM8jXraQYmCmrK1W0u0OHgU8OCk/ynzr8b
# DATA Llw8oTrldYQMJ5WhUaTTqVqzjLJ3OWKcrBioRdylRWBce2V/wUrYnFUCa2zTxRrj+HKOL+f4co4v5/hyji/n+HKOL+f4co4v5/hy
# DATA ji/n+HKGL8fqjQolxz5PSvR35Csf3qOvN/WvAppjY/PjV95Sx/9CcxISh/WYZMZMtn4Uj3Y4dCariX5mtv8x/W9yd4bbJFj1gwKw
# DATA qW8Mh9HhhjTh9vgEz5LAb5ZD4WCsRzMeEQzuzOkguoP2qw/auwP2L/AB+4uqHz4zB+9zx9Z6NUQWeePTrBMaociygMDykL6v00J8
# DATA uuf0n7MTq+ep7+SOyqvQRiypEGxZGLGs43COKuJdBehhMQTKVWpDGQdmpIXen8MbwzsYvMM5oGC9iNlggaX6Dd0DmqxjnPbu0dUE
# DATA Ivda/VBkohjRoNQVqN4mWsBZTpRzVVfiDch+PlOOc+g9qRB4GnUuejiVaYVSmS6rHq5VUio1OXivbfgFq27fT2ikG6rT6rL5VYtv
# DATA vxdAbtHI9KfRcZDiQL0SFD0ORnI0P1AV1BshIcxJYAd6HKQiTCGRL56HngUskvqD+QxJMoegyxrli3HUuWyoDRMpCabYcAeBTRge
# DATA voRRYKTUg4xVGpSwVsB4Gj6tHs/WRO9tUG8uEDn0IiZilpCGrkgQwMyo8INUAQySUaZ4jIamw8GkD7xj9EIcX5y2XxPJ9+U1SzLx
# DATA JTqxbofibGRnI5dt5FKtcrJUTpbqMtbxSmv8yuSqvhtzG2AjIVBCT1rBhnLsgaVddc2aiNcBBxbnDkNwYD2mEXIOKpXr8cD6MdM7
# DATA mQs54bZRPQ8RXK+KIbsBJVi8TkD2GgcTX2KXEF5+ToT18ybC5kIe4ebyCEscVZT9cpSrq+PMrjG76qJq7fCLb4pnavfcbC5SmPX3
# DATA PM61pXFuXjbK2mFGN7y73Od2TozzAEykrUtWXi+NthVrVX10pJuFOK8EIr8+j0ehNaKht3h+ucjvyjAso3sw5aM3vICt51IGnMy9
# DATA F58SUepQkvwhPRSBx3XXG0TH7NJmx/HMeFShg7VESP4wZaE6M/5PoiPNvDISYD9U/bruCgFcC4BFx/5ZNsj3vb8mSyHkeQ/1jFY3
# DATA S2Z/iJ1BorqmGZniypaOlBsLpUjezKYHpnQ0zRAOXDxbNWV7gY1we3R1Rrgzwhcc1QvWlrPDnR2+zqx+dmRj1WCnmwH7wNAWbBV4
# DATA 4HZorDKt8Cgf6pREaSVXMeWhxgicQq8Te6sw6iDwqUh2YnhVTkS0uYEAUbJ5LJgZOQyySnP10vTk/KXcsCGB30Ol0LMIGp1Dx0/e
# DATA hJ88YR8qnhBv6uo7xZ0sUwh8WkNO1m5Fy/kHiu2zT1DOc+OCGMkPVyMkdb4KRPJuwXMPlzZVGUBp0wjFVAKmptEh5Zjxz7IfVpBY
# DATA 9J8B5s5KfZZqZMY30m2TWUwTZlmB4LnyvvdGkKYnEGVNJkX3eBows5Gt1ll6orzELMqKPZCpRAw+82Si/eRq8mA30nz1RzeRfHXJ
# DATA 7IGUUX5N8k3+ahVFusCbfblhBmCcmpnIE7FC86p8wWJ+a3Ux60ahitk4/fMlGdlrwT2GLuh30MXCyAmEyZqSxa5XOTILWS9aAKIU
# DATA zUsvEng2So5HJyIJnbKyMTpXjEVmqYfKnDfwoYMcml7xiYpwfdKurRALvcwFy/GDNTDjvL/SLVbQI0oiOY3AYqUhZxIqMXAuSU0C
# DATA y9tpGAc0CxyzgTqIZic0ns6Rx7FyXgW6JSvcmJnM86ILja45Hy0zSzg0+D7EjJR9buwBwwJhLMC1J26b6xJ6beV66T74/sZ9MFXY
# DATA Gd0idN3ImzB7O3twstD/araNFCusGhGaZiNjGI3jbMra19473GMG7CUYBekhZKWhzDjJNKf+OEmlf5W2Ip3rIAAiGW6BrbTL5al6
# DATA 9rvV723craqxi+wryOsjqYEaqMJAE6xNk5R1b3SXiTYWxQ6Ft4VPx0EcB0Wp+Nbx4QSuHpmIagsTjhWWBofRmU5T1qunXleKmeOx
# DATA jba3QcKei671zQt1rVrWHYZJmAbHaCC8O2EUD6yFauVc03co6yEKsC2UMgey92Lv2PYMZjRcWNrk6c9n+x67/Mxattoe0E+DKfKc
# DATA j4Tq/RTaQ/Zk5bo2hZcq0esFeD+Rh/bF9ynmCMx+RKN93M+KCMwvzj47/fz0T6ePz35Fn38OniWwlX+iPz8Hx/LsM31xGRbzm9Ov
# DATA 6P9fnH559veMuzz7W4Zi/kmQmBz07+nKr5if+SWTM72zX579HQCaZ79kOiaFffrV2T9SEL+kv7+hd1IIuOnn9MMf6We65w/0ksen
# DATA X5/92mEynwtHKbalobtS3aKqeRx0dkt8UTyE9Wh6UOHvh9jsDi9qH8g6BWo5CthzFZgpgvG5Bh68cP3hvvfWw+kI5gt1pigsxFoZ
# DATA NLk68Fp+5hsjGr+kJSJ+jqBp+1B1n3HdBM2FQrk6hiZXSnMXthbymrryAC4QN6lqx4m5/T5/9SDaNR9BJGybAM04k6jAeyg7GyOc
# DATA +Q3ADzqJZo6euUnZXQE5k1dJebU8HmOqi9BMBVDd0yziI2p91GM+1u+9GwXZXC3fUo7NAYViugJKjvpK43vOmDPkzeJRpFzWKfvL
# DATA yUAK56NFnOZmVXK1pVNua0+LqLlZOhxS09kFV2EXaNbmZcyBl2I59dpMge1bAhsZAheyA67PDJB6WcoFG7f5rLWpq+BwlpLPiYab
# DATA mtmFJjJl+KZWKM4z5whOjJHicdoHaTi3eOnZKP/lAD79NmSG+HI0vjJ7EM368HtviuPMR3zLYqDIZfnwPxY7IcS+PKhGQaGG4utJ
# DATA iHyypmAP8MI3xS0J95QfH+08y3gfmcd7uMQW0U5FGpWQXPFHKVonb5Rgt1VgltEcetOhNx1680rQmxuNNRtNgS5iNF/nFOAyM4Bt
# DATA TQAcetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3nxn0
# DATA Zr3ZCFu1y6I3W4P2oPMcoTdLi88bwTcp9JiGRa8vMmNdzsv+idANu3nG1hqiQ8W/1FpFfmE3HESdxVwGE7BWH/q15id7Ha/pezXf
# DATA 86td/lNv7nUaHtnHe936XnOv3d3zay2v1t1r1zy/TV/qxcJodTrNbiTvKMa51qjlcab35XFu1fIoC1nUqhjNeitaRFm2u57fbA87
# DATA ndGeX6XotT/pUmRb9b0a/dDq7Pl+Z6+912zu+Y1uqbb4UT/yS8zDXisYBLVlzMPGsqQ0JPZ9FeO2BWFsWEkp1vGw0+/3lhAZ/Y5X
# DATA r3U+6bT2GpSSeterUpo6nl+rfrJHZVFvUAp9r4RWDKJ2o7U0bs1OO48bBWxlc9eqGdUiLdJv9ButS5AauelpUqO0YovUSHHpdzch
# DATA NRaugNRYizpRaJEag1bYDnNSYzushYFFavSb/U79ykmN2Nu+t86koQHX8nGJbWwe0paMDSVEKgd+aUbc6Hzbw79kanhsbuRB6PHW
# DATA WmKUX9mc3NDrX7Pit3QuwSFCUNj2+VdxN89BtGl6YBngBVeoKveLgRXF/ZVDIUt50qQ8oX/r8m9htarRNNjIdvPbSwmPYixSmmXO
# DATA ly+XWgtYyxGOK1GN51YGbU8urwWSKTW7+DYOp1Q0PIstTYYcB9JxIB0H0nEgHQfScSAdB9JxIB0H0nEgHQfScSAdB3IQoHHf9veE
# DATA pyibjgF/JGtGIx/v6/Pux5HyZzLucUfhInEBT0hQqKr3sNFvx2ckY38s7MdCIGquaoUiV84PRkRkIZ6sjtPLUXtvGkf9SJ9GxBk5
# DATA +A97KI8iBzI/eeNOh7vT4RufDi8f0XIHxd1B8fW628/MAfL78UNpQhUanyYnWPKP5ZClDb4xRx4t0VQ0mZEc6sSzDxZPPeMoKPe8
# DATA 6uz0AKHIycwsGEUXlM82qpbieuQmTjcnY7hG7XPeTjl7E+Vs3lHCVREfVt+H/hK3/Yj+rtHMpkFxJvjD9+Xj86CXbfLggiKRr68W
# DATA iVS5KQKRr+MU5wDHujEo5XqQ2CzjkeVOVQXnwXE6H1xWmvKcQMBzFA/kBHMyYwpExkMTXFAIxhtEVI9GMIhowpLIwWNOiSaiPIl2
# DATA 5mWz5I0Ns+QtrQlKY7LOkNeDEXQFWKuXo0uNiS+YM9eyhMOyot4A3mV6GjnFCyQ8rwNzjoZm/KEmSNZfLCfzEdhkGxmj28EF8+VH
# DATA q/NFWpSqKfOQLZO8jkyClOak3oTmtB76GQaDQroVCxKQGcjhP7BouEpFEyGUQZAgY44IfZ6ivz860cbNU6wj/2XDOvJ+MmcNi5/O
# DATA D/P80GrTU60+nYwH2DQCTAN1AlNMr9AgmGakMEYhmRo0mPUp40bDZI4Tb/veh5gQsLYCKyWIXXc4Cn5mhDqeUH027wovmD/vr9Ge
# DATA 1Z2q5BDNr72pviQ59H6aHKEOUJppdnMYGXQsb5KjShPM+1DhuDvx5hMkV/cwEAhmICqwTCMo70MqmheXn2K7+WDDdsOVWim3WMha
# DATA VmQYJ3Ooj8+hVDES4yHlM7Lw94OKFYa6Z4HScixdKZtlthBvINWF+utyflyvlO3LotCQm9luEu4m4RtPwt2M+wWfca+cTD/Tkm28
# DATA j8XsaBEqK+9qufMqNehyCev9l0iu2VbXka2U1uZQuRCM+FtZ/mxhX6RUmH6CnUPyspNJX8dEnTS+84OFbZV6kr+oLmc9xl84NYXx
# DATA fVQgewE+wawXVhwLqXrSBF77F/KH+Og0DzfPqG7d8yTntKGwrWe2VEn1LRgOZgPVGkPtP3/7T9qM4FcOayJlJxakN4tGI566KNCE
# DATA KHp9F/Zn5h2KlRXMmBYRQoWNZizD+biniyvw0uHJbDhW1iwbrDw3OIzlZ7H8WIwM02aImlmaXx7veYRIl5JGrlBupVEuOGfUAPUK
# DATA tGCGcnTFcZAuaOoWC5ShRsZwZGLVSyirZQXjrDZntW1stS3UN7d24tZOLmGxrTQOr1J8lwFNA6Wjz2LuyGteiC9o8D59Qfh1hgDO
# DATA +Xn2WsvC0onYimxbhoVrhTUNWeqny/eo/+Wz33zF2+mPzwPd60dNd2YumBUGOSBSRsb7RdC9jYyv7vur11/UhgI7snJpk9iah010
# DATA 8ysmvt1tRldtvKDf39X6v7NkVqgSO98+L9omEBPt/Mo52Vy14l1fG21lvpoFM9mVyqtcUuUj3uJhmkJmIaJQw+68KmeCVZzV9mTb
# DATA qZZfkv4nFlTVlMZuZcTelCCeEP4kthWjtPIuwFal/mFm9peg8Rnj9l1xphqlZkYOHw/jUZT3EzHUamfYq5Oy5K1Z6aDWHOXizSwP
# DATA rFY4YeLKxhXZ+kambqkK6J1WXqhQfaY30NrB6FKtvodSNR/T/dgenIfDetL9YALt4CklIMY5xSCd8kIve46BIoe78ngYiQGfd1xI
# DATA GYSmuV/jhS0yOvY9BbNDCo3QdDafUtej9IOL4tI3Od9fFuvZgnDxHJ3nEDaH67fM4Pri7BfCuwI565vTPyg0F+BcYHF9vkjg+he6
# DATA 7TEAXYLWOv03Kxz6xICtr+geDdn6+uzXp/9uKF2nn9ONj/ldvz/7ByZ04aSDd/q70y9O/40qTTBywK3nwv5n497augFUYJoA7zpG
# DATA P8H1zdgxTGrNIE9OXRKr91HPOBHV72PWDZelCy27XVHc0EM09mHQQz8ls3VRw+Y6A7HzXoQZwjrY1kd0l4mQQ20VTP+8Z7hu2lap
# DATA VK6OtSW0b8N/4i3Z1lutO3+aUXHrG4sVbJuIrUDAVhquoBYIJTEOr3VOcW0drfV+QEYnfqZYN6uVarXKowZlAHVR+977NIAYq4cJ
# DATA FjzpGgZTrAXrnf+zoHeASAqOOjMQChRX9JAGApwtKDO0zq1uq82UYuN5WvCscxPguFlueN/28K6ZWRcf1V8OZ941jujbHtA3Gs83
# DATA Hs6vZTSX2lhIuu2je5ba0FUwsgoJZ8RPppjtdjJp0h1katEsxKJZD5Z5gJ3EFUpoDKQPNZqYkjCKwZKahPq1gyAewV/ZD8AqYrZQ
# DATA MVkYbQOT0WMa4PQCczzJpkgSXKTUQjalZeUhs2ZAJu+j+DOlibeiD6nOwb1CF/lMOZ82Z//GBCt8PIedMyFqGogDNgkZmSVmQWbO
# DATA ilOK7p+Q8fYQnrI4DNRJ9kgMwyjDPsQ4G2IdM4BXoy/cFaQrHmADYn8YjQOPd74zhWvKY5FDaTmUlkNpXSFK69wxaKOpzobm8/XN
# DATA Ai4zCdjCHMChsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6Gz
# DATA HDrrmUFn1RqNavPS6KzGoD1oP0forMKq80bgLM5YjkuXM07QTFW/IEfR8jvFDK93u6tzvFrvNhZBTt0aI6lUUBZcql3tdLu9ZXCp
# DATA ugTSj1OWoFIva1lsqTrHkw/MdYo0qbBbb7eWPd9sbvR8t9dt9ZY932ls8nwn6rUDv5wJ41qj7tVqrT2q2M0uV+/auO439/ya7/G1
# DATA Pbm25/v1Pb/R3mu3Pb/j20HzhtESnqsTdsLushxkXFip5re7XqPuU4XHq73qsFstBWfybiG47iUQWNyENAJLWqOFwKq3Wr127TII
# DATA rGrUjQILgVWjgNo5AqsWVsNGjsCqdVp+q3v1CCyaCe3R7xtN2ms1GiuLfqvCSCMjng7R4wNyhvukbThlfOoE6wBS7VpZFog3Hz0q
# DATA uUysMWDh7qBk9htTvKNM8fwBPWqX54HL5nzaS9hhL6GsDsJPuGSxrVVMRHEhQOaInj3xUYZc/oQZBpes2JUxXEs9PrqiFj0Mq6Bd
# DATA xnmsogO/sTX94u/n5FPxRS0kh/2Kha0nq5834/Q5r1kxhVuN9TIVfCMc17rKu3paX6rMy+rkfHTu5JKj4DhfjvPlOF+O8+U4X47z
# DATA 5ThfjvPlOF+O8+U4X47z9ZJxvlAX1An5KDywqV8zLJlyRiB1t6WuJ/O0H6GCcK06iAdsZKqGeadZhcEzGwJW8FaaJojjm8ryQvMi
# DATA k4f66PRQ+mTz2tslY9qaE7AJW8HkoiL0L2xr5HLYFeaYCYS+U1fx8Sts14h57t3Lj/6THX2SLekLdg8+ZRv9UR4bbLUcxBPKDkU1
# DATA YxlRpftwZAX/Bjofaq5wqVZwjnEcyBkqLnW8tYc9yjS/5BdZ8VOCutTV4CTUe4mxT71jnFlU1if9xhGkas25j1M7e/pH+uW1dXYH
# DATA lyGVT56u23nKdh8VIiNiVCYOWqRRvQmnAREPsfoPPjXG/MevmMD3ETd6q7lwg/oqUNjoGrX2/BjkTblR5wafPSqnVyXXVLa17YXT
# DATA uazwNguGJnN4PQXE9rLk2Y7Y0P1ZOqIp39/8jXzFZkD6uvtXfyXf6VHK049feYsRD6/sPlpheSujm7rCbHafLfYdKVQnce/UFC6l
# DATA puBUFF5sFYWLqts/VXUF44CVFIlYn6XkPgtQ3e68p2W4OaV8kHUOact4dULe1Gf3c+UBiSUeWvfgfW63vM0Li0IrnypkhxgLVtvL
# DATA n7qJmGodQj4au1Lg3pCYlBQCter14vbPnNjEc3C4mv+7ZXJCURRj29yEstbIUmrCRVWyPkpjZbrFE2Y1ku0GY8aoZBkdEFYuy2AB
# DATA H0PIbDwXDYcT9lNXjIC+VEZVebiiYJTMRNHe0vSAxkHAFn0ymDFcKY3Yjc4ELgXcYkPf44VB1hufRA/Zx6uUNc7lGL0Y5+RNCM64
# DATA c8bdRsZdSSnHaWY5zawLWHUrTcer0tJ6WwSbqGKrubxyInA1z8k+163YeB0i98qzoDNXJ/1VvRNDK47r26CaLp4yXGZnWUFgnTJy
# DATA NGKPNgMQsFbMo9tfwcV0gD5NPt1SF5RFLd8q8ofd4uq2H/uVWqX+ExoUdYxWSMorpxq9623+xFW2iCA2t5i+NX9ogQBcY2TDceLx
# DATA VpI14OGGGN7gHpbuXAAFrxSTNz6svOo8vzrymPKIvJSykZZJnM2NwNlUWk1FSZj9l+AouC9drFIzA2FFu0HRTFQ+sN7b8aSohSaq
# DATA WQEgLbZLTulj0YAJ0TNBJI1OlCPUNHcoXIkAFz19jNNdPHSy5pTl/tv3THFhRCQbed6fzRWFaRSPcZE3GkGwCiJxTLuAdlemo1Kq
# DATA CPlUxDaT86mFlFbRdYq5pV7hN65DNeczNed82fkXw0LNhxlnojoTdSMT1bZFnIHqDNS1hufTFnt9r9BIJhjoZvE4hzLdl2VSFkCt
# DATA WBRASZ33lpZBhMAiju9wdtHvaCphwmM1dDlZLTQ4pHhhy9nkxOhBbqjgytE1sRESFNUCCDqKQUCNldp9xPqW6DyWeOvUieMllqrs
# DATA UUAF40+KDqQsGf1jblyZKyw9AeR8xOGo2MmeG9MtrWYVmY0PDP2Rz0W70rrDdIn2UwsmI3YOYHRExyj3xessTLRI7UtefZelYysY
# DATA R/N1TchRFh9y2t/kT2ts1yIbXHYS2AaLopmvMhsLZYzd1dJYLwFg17lxQQD7o09XE9glY4XAjklcpBnpyml/oknsH2LLKKU8nWey
# DATA 3Ytr4IS1U5WQLuZAIHPqFegYmzACbKDwenMydJViatzf996MWWB1zkK73jjOePYoe12wXYkporwJRK5xa+WVYSExAEFEr0sVn+2J
# DATA 0falGnTBDP7Pv/9qdQ4XaqNkNEu6ppEI/8KvGvfjmUHe8y85fYm1b8moFi3VZKpP3c+otqWs44vDq7NY7PO7Az4UTnODcS8+nIP7
# DATA qFy/Fd3dCSpK6I8BGfss4RuH/JtM2LeRo5esq+Nss7r6XjCWqgAp6zzrpLZgigMFW9nnK6q20KkeRTMgsWR3k3naY4wHei8GfZwA
# DATA LSu0rgmUAdEgyPqj6FDvSUWhNiiYBvL0q99/vVDlE9YZx55S8ck8mkc6/97BDA6TNppA50rMx0HMzhy+oI6bRwBAvykNktckpOJk
# DATA eUXlgJH1Axwt4PykDJzAhcQBzeQpYHojUBRpqEShbaXqma79ghn59pq6pwYJycPyCqU3S4MjGjePKQ06Mz9QRwmGSiA7kGqZkg0T
# DATA hZkyCqiXm8wYHIewYJfI/IQa8sT0DKpXHVOvkfFcMobEo7WsmsPlZrGSc49o/qtVuGH7PdV8/XDTfP2QCXzWchXON+atWy2HpdEh
# DATA 9oPLARFKSKaGDIw2uXq9kTzP2FeRW4bRYMA5bPcDQS9j8WqaobF7R+5R1Rm9qVh9MTrbn8pu1lKGFo0E2bNoGwnmimQP2bV6d6Ge
# DATA 2LGzRe36o46oP0ygnxXAX0olqQvipVh4szF6VBKRTdD759Nvzv729IvTfz/9+uw34N6d/RxIPPrvN6e/O/u1oPF+f/r52Wenj/H3
# DATA 9OvTx2e/WSTq2eEwK+/nTOPDs9+c/QpPnX5JF5m3J+g9+vsnj2754uzv6bk/n/0COD3EoJdGx3sGvffl2S/p72/wMxP3/uTQes+D
# DATA t0Zqms2blynngxitdCLbgkFs+KHxzYjyPcwxshhCKP2wpSDrG/j9gd5Okkb9eKpsrmyO/ohb+zhhsf61JL03JF5WA3IwPdtLg9y5
# DATA bo7eYplcHUpPqk6+kviBVCWRPCnfjJ7IWnOMjq+Els07qqfq0AVlhUwY8bZxNJk7nt4GZbZ1pJ6Y9dyXc9cDL7P4zXpkQOjeTex5
# DATA 7sY+zLslqq7JsYL6aMI566wJ+pcPHaDQ4vEYZ3QAE6LCNjDiC9W/NRjgcqN6Woi98xPhGHtunH/CcV4j9S41vL8kCzDXMrRfwci+
# DATA 0cB+kXH9eoZ1qZLlHLDQek+z6VwFSa+cVL0oIi7VgOUmSyNiZg+JiP/CmFgRKJYszsoaqyhZHEWzZMrPRBkfaE/IXJoNkzDbBJP3
# DATA AfJQlrHKMaLshYeAN+5S8scxNpgkZJVhz5YM9Hl1oXcG2TwFGCxggVHKZPbnV7TbPo3QfjhFJ1wyooMjJEA4VphUpytDFowE99WH
# DATA s1rzzBwNz9HwHA3vCml4m4weG81VNjV2r9Vuv4zZvg2r3VHxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R
# DATA 8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFe+ZoeI1W7VevX1ZKt5g0I3C54iKV1553giMV6C+1bsWNa5erRvqm99uF7lxg36n
# DATA q/KGIhjTyGqCqOdBNBrVvGxqQtuTw1O1biG8dqPWr/cXCqrW9L1arTastatHfqPxyV7L6/p7fr3pdWv0p7rXwZe9bm1JyS2i+Zo1
# DATA Cq1ZHTZan7TbXtvfa1A98BvnUOdMYAuYuFp7aQZ0LHIfRd6qnPVmngH1wnu/1ejXWvXqQpTrrarnN/1P9iitDaote21/3GxQ3D/Z
# DATA q3X1lUsnwK9dAnTHrUKD7qSBWaC7dqNebzQ2AN2Fg1YRdBeE3X4jB921W81uq2lAd2G7X+1ZoLu2X/cb7WsA3aFJ7a23NzweXqxb
# DATA y3y470bUC8RBRQIuLeYtoOLqvGCWL5cVg1Z2y4KTSufQgiOy5O+3w1rmgb/QoOqx763KhpN6Ri2BLU26casuRtKY5UWEnApb0HXL
# DATA twqUiXaLmLWlOWMGPr36VV1Hg9ugFlyVKeLQbg7t5tBuDu3m0G4O7ebQbg7t5tBuDu3m0G4O7faSod1smJskmw9s3RaQWohTbq/s
# DATA fke+8ZIjY7kU8iyZBSO5Hy3qxrvBbLjPM8kdvrh7g3IAx1HpPcqJNoXGzHzKt+8U3nFTvtGPGfcis+QetuPt+HYoH8lhMiuQ8jtL
# DATA wfCzC0fONEFMpoDmSIc7RO0OUS87RF065uOOU7vj1Bc9Tr1G+PaqjllLK2A7GHrtsspqjlk/RSGP66AuhOp4tqoZ+OrtHO4qSVvd
# DATA 7CbswMgF4NVTed+kvufMgiKLYRyzAF1TYRvY9y+LTthiwWtR+/5q4VsZTyHFbIY1FAMOVUv+nxNd/byJr7lgIuy3lkW4Y0W4tnl8
# DATA eVAFpY3jwdGkK+dEUj2U6/aq7wUOxEIMfSuGHTuCxeit5D28oVpUZESDnl/cwxts5fEwxgAvTE70geS3B1DZRB/Cx/AzHujQ9jIy
# DATA S6YV9mlSKx3B6z868aCkiUoWg5cnRpF464XOJbWOz41TM1QhhhQEBQgzZ6gD7CcwelRI+jg48ye4JkfZDOvuPKViCaYxW8SWCABO
# DATA g7MCIy+jhjhJ5snazYEtBgCTDb1flowj3RG9Q7OXI8yQhgzA4Pbdx+5glSBEO+9rzgc0vDgHix0k1lmy6y1ZZ7e+4HbrRaGwT10e
# DATA iBfMrYXgRaNvVJAEZOpPxqLbin/Q42OkMEXWMlSfuqrQc6LAcRXY1AUFpG2TU5eoSS2Hp26mhFiqf8hqm6bAItKvp0irGtZZtT1X
# DATA kOY9PXoiNM8ETqX5qWyLRZhnhScFSZfAw0aJ+VjZZ6hg9CGLlKGEwKQmFQ0UhU6+xzcYo6Qswc1x/oDFXiXKEWWxjvHbZqIW8xyQ
# DATA oip6RrM4rbAyO8dGq7IXLDSteG/jA9ggRVBkBeAIxppov4+FufWxvg/oioo1b1OKQh3xt7TEVUizW8SGksC5V+EpX8U7wWZZUXVC
# DATA jzFLDiOoWO17llGdsLLo2GNQgaK+rIqufuFijF8iARu7T3KWprM0l1mahXHKeUydx/Q8A/XpC1NKDDKlrJgmyZhV6rhB5PKUo5E0
# DATA laUiifuqnlfEWVGRwQi6c2hGWJ9mKhh7VjxZvVPtipcRL0YBu8dWglJ3lDaplhs5TPR8U8ZuwgUcjLCBQQSyHRRsEyiYWFy2abXq
# DATA TuPnZrqL/rL6fq3SybmqPq++W8t4Fs2PZx8jluffBTku/i2/tRrlogtDUC4/mETUmUzZtbiHI4vaMsT6ht/0Du2VjFqjSheUG/Gj
# DATA SBHIaAqCrXKjkwrZ7dj726N6McDXGcZLhIw9JBnWPORUR8Y9BIyt4yAbipaqttDp0miUbYODcy359+FxwvkX0jg1LeZevVrMvUbH
# DATA yr37vFCDZHNfqzIJiqUAOs9YjlKkMeUu8QuPIuCLsFnXU4dwRah0C7lVaIMXz7Dm6gyzGrTk2XepT6XY3Ut5KjuVCUyeb7VSrau3
# DATA m1a+zWBK8TIZG07xZD7DkAPR0lFxYsUjBsN6qObR7EpR8Mwk7Ag7GkfPQN61LpB3b6AKpCIrka8PFrKvVO3qtWop+yo8lWYT9VCK
# DATA IqN5qiilgtgnrRH70cM0OMZWXr00wHqz+dLAk+SZ3YdfMMveXZ1f+WigEH7Jg0Bb1zqT7jGnQrgRQPcJvfCIbA5jppOF+4Aa3kih
# DATA nUJWHR4nIZP8vCHWgb0PRCiYmVa4YpZPzKpMRgM95Tpr8qJFbyPb7MHswjWttjrj8oFRMs44BooGms7D+7iqvC4Tz+9QDQt1XgVe
# DATA vcV7hqiiYlsguxBouqQcMWK7MUae61riHc5jxfdibqzy3rDZyFvOn1WE14vikMgxXoN4BolZm+P1/54+PvvF6denX4Cx9dg7/ePp
# DATA 708fn/7r6ReM3vpiEdj1P+in351+A8bW2X/DLZ4guU7/fPoV/fTl2c/Pfl1BOBQmhfU1/fbv3tmv8NMe3fGYfv8Fv+nx6df05i/O
# DATA PmM8GJBdigD2C/r67xQg/eSYXc+DSyWH+qHLHNs8IOlDshg+UGqSGheYzvszVr+XDoUyLJoJfPEI0794LC5IabdwoQ5w+hwcACiU
# DATA 8FPgMPJGVN7u2Vca+UkwWovxegsr42FwYmLqOF62r0V1ENcN8lpSKldH8lK1MF8yuq+q5SimeKYn5fulNuqb3y5U0m3CvOAyVDER
# DATA LXzZmR/peDmg12ZFt3Wm1/0oBx3kLIgUkFTdZRkqB5ecl6G3wV4gkRFmqII5RQzPzwm+7nvfi0M9O6beTabX4pxSKV0ge51fGVfb
# DATA M4ut7Gmhvc5PhUN7OXNg++aApn1dzgp4KVZbrssCuAoDYKPx/4LD//WM/lIxF3LBgn49Y43qKjhgC8kH1BRrQxlz3tenrMI1EKpX
# DATA nIRyOt+eqa0RvAWCRULiIDVv0kFxymXBCcWpXAcbkcE+ZF8v/EHYgJPB9RalwaiiLDka0OJwjuKLQi5GGGsp1RBeQw5zzBNHWJsC
# DATA ZscIzAMKVFwecE5RG4drJp7sURYziN0j62IWTyLtqOLlM4SOZWiYLRWxWejFYocYEJSjhDlKmKOEXR0lbMMhZ6M50Kam8/VOAy4z
# DATA C9jGJMCRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCnMkcIcKcyRwhwpzJHCHCns
# DATA mSGFNXr1kH++FCmsPWgOes8RKWxh6XkjVJidL37Tq/udYbPVLdGmWtQ7dqJltKl6R3KIy0jKoMGKlELK8v2CUk+57Gq+XXitQv6b
# DATA dxZCb3b9Kwy928oDb3QLgUuq8sD9esuGgBUC7w46vd6gHHir2d166AXQW0NYbAIp81s56K3ZKQQQNYOgU19oFvS45/udo0ZzVOt4
# DATA fvscAtnqOtG+BICMG5sGkEm7LQDImkG3tQGArHAFALJm2B9UcwBZq9+MOlUDIOsP+rUwsgBkzUa/271yAJluoGvhU/t+U1PICveb
# DATA 0VEvEDQ3oY0Vg9C8sbwf1zm14Mi0Hu1hUWbJM5suC+y3lAVSsx0Ptf0la8I+G0SFNxc8CmIZ4Dmevxhvkt8kOwEm1RKPZM14JCVT
# DATA ysssSxb6mgsvqB3ouRb13n5ul5Si32F7bhkXrdvtFmloWGVeTSkrlFulVBZrrJ3ijSXfg3EfOgyZw5A5DJnDkDkMmcOQOQyZw5A5
# DATA DJnDkDkMmcOQvWQYMtQFCiUcRZWIl4nC29UKO93505TM7ii7/eOfVOBQPYpuswVbQUf7Pn66jSp5YCo0ny6DdZTu7D6KBzvy0O4j
# DATA HTS1UJggwaQf7U/IQt3dU686sIM/YFVnfXBjR6K3e4Cu4ONXPsyPsYWCE/vUmuNgH6F+v5Qijn2seS/ST09RUlnJgybG6Y7qraBP
# DATA LOmnBEzCG7enavd+9h0YdgeUPgT+Kv22+4ifvj094DMZFCf68S/4GsVjaWoKCTZZf2Ay/EBqHSb03OjzGkZ5fk/pO1PeKyScPvlj
# DATA lJ+9D3FIqnj+MqXoM8GD8iNOJPvElj/4dPXrmPTWj+LRzg4ldQ9p3r3Jpi0gbypLKCaUZFMvqCFx6vfZjbv7KK8w1mWJu30fZZzN
# DATA xctrkIolclVySI0Fu4/yDEPRoThjysb4VUXOY0k3pDO+cUPfvD+dk2nySMX8ltyJU3Z0X4UjQhPrj3Dq7j8/+7/UmUZg8+Ib/i51
# DATA MRSJheD3/N01YeN4pB32Bzguycsfi6F/mteFT1Ud4cmkbpOLVVk9cFCo/QdSz25jBqurnnVDpdasFltUOp+IlLAQ+rg6cCujC6+t
# DATA M3DzNq+eSnGG9LynuHzt7sKq+XkOlPqZdU3iA6is5u1BJQpR0Ukyc8Al0eIzKPGI5kOmT9U10DwmY8VuIdIU7HE8oeniskCxkkYP
# DATA RaVMcswYpzNxSZ0Jpy/x4utLXJQk8yzoTvDKSsFfvx4n8y4OwYPIAfFVfXA6OMSrZsk4SWlmtpYp8yyKVjw/R7ivgjSzqLGxbdTM
# DATA MhGTS7JmvMISkVRpXmG741e1NLBgNo2cGL1M3QIBT6knuciHLfT+gKyyirieRMsekTeWt6zmJVPMIgHXE9bDcJ7OWOorVu+d0sg/
# DATA Ef2EREl9GBH7NUIf5ymPvkBH9AsNx5lQzoTa0IQq9a9OtMuJdlnD70rj61kQ83p9HoOpVZStMlJe3xVdKLspYeSZRgka2vEwKYxQ
# DATA ghDQA9i+dxciNig61tQJZC6s4GPRA2qOwSgeQPEGottwPoiE1CSKQo0Zuyg/xURUAR+UnDak1StLlLQcPGUTeMo4kaJjvXv1eR0Q
# DATA JWU3mkjgy+fVd2O3j3Cz3+BPq+/U5o7iC/Hn5wGdYufeBVXyOzAcV+vk52VRYFmwV0+L4/OsKB/ZMH6lyfxwmDeGnzLsnSU8NC5p
# DATA PiHjkbWo8g3TaM9HSczaVn02Dz19gh5W45zF5qYs3wtjk+JwGM22QRl4gvxrXiz/3oyyBx472y20ALRxFdzJpJcl48QVnjHP0DYd
# DATA joPRA8orLR/I4eG2+QiYbkY1etGEy4DF23AKwgvnqRbXpUFqO0yLvBleFM5QW59veauWfHudxnjZ98dMnXlsap+yrajORdFKIUOs
# DATA Hk3AspC8ZGk6WUzIFL0rymb73vcZiBH1h5P4k3lkFBSpktKEDqyE2RDTjmHANRH5OlMVdwu5mXdTF83Lc+qg7vUkJz+iusMqiFqq
# DATA 2WBITSZRGrkKsYWqUKMGCU8Wbv8BpCBLpqzKvYBlFxXybxSpSSZnu9KQM6Leg+Iw/LRacOtiLfj1YMR2hJoqRDaLBsYBZ0g2n2IC
# DATA RgkM0t6Jmhv0RWdRdjrve7xSg9xlOfJUsd0o1wZRBBFFTLXIooiyadSPmQgr6pfpCesZmkn4JDreRg7aY99FK2B1fRbmQ6mCraBy
# DATA peaipuDStGvMXRs6e0XqMdOwfgAqD2XUMRnYMNWxg8IbkkWI+oUsYxVQFj6kSg0dyCNsFVN7bJ5ZqMoL5NrIg3B+DefX2NCvUaxp
# DATA zq3h3BqXXBNa6QK5Mo1yVWUL9FeY4lTNjXfjqbMy1nk3mMm4kmPPG715mQO7v9XJRX3NTHp5V4M9cporetbLuZSfj8TOEPqWDAZi
# DATA GgSh2AUFhwTvaqGf2UYyvc6O2p6yq/wiuoVPeEM/XiGRUk+bnlF/N/P8uhzfxDCQknFPxgufucPFcfBQ7qjKObloykfzVvtOeJMM
# DATA p8Qq042jqp42UdXfTVRr50bV72wcVdn2g8jyp/Pipm/PY2eumPg1lkXPt6JXWxM7tSpo/FlyLoCnf+Dt3eR9imMyseVGNj/S8Z1X
# DATA RVohz0IcC7HrYH6pUOemNLjP5DjuTQkir8jGN2O1D3NphQNHTCKaDIaWqV1Q+P9rsk37eoJKE/MBRkkD0pEpw3FAwztgO1N6lAw0
# DATA zMAUFSifxWogpaITqsmWUFLN3l8LaYkhORntMcySd2zRW0LwMBOhicKLUvHC+Gc/izGksHtlMs8gyJ+dkO2bjLPci2rHbBiNpucs
# DATA HJdKNV88tv2q+TKw5L/s2aLH38eHvMQvFZhs5ZJGGc2s6iM2LJfYy2GVW6zDeUo2MZl0Nu3w/2F44RegDRYZhGf/iP8u0g7/+fRz
# DATA 5hF+dfrN6R+8s789++Xp16dfnv09PfkNfVLcQmYcglgogXPIHgMRPwdG8ewzuuH3Z/9AD32J2745/SOFo5/8w+k3wCU+ZgwiBemY
# DATA h8/DDMNUr3xiwRUexBPkKD1TUf5K7nA0EoOFkwzdWSJMFtH7VIpCI4BhZQge1JNqo2caR32aja+DG36gtzHQAMBoNYc2tCYTusCu
# DATA G264UCpXhzZUdUTfBs6GJu7wLwv3Y/uK1eHeTwZqT8vW0YYcgQLYMM64sjus4WbFtnWs4VsPpyP0MoF2hoyTcD4KQF5PZqzZs+99
# DATA hL6f+658nxcvfmFjPD1r9j9RHOZj7ikz2QYFF0oyC/RaVjARdMwC0PD8Krjaaim3rKeFMzw/DQ5n6Eb6JxjpNbfwMgP8y+EpvLbB
# DATA fftj+0ZD+wVH9usZ2KValvLAYhY+rZZzFXDCUiqxAgASkOL8xX0rsfqcYzlBgbg0FVQOtDW9iTpD8fDma9lWrCW6YSVN2CtazrcN
# DATA iYTGy5rHLpslfV5x5PFYo+KYH8e1JKS59iQz0Y/maeIFY8a/8ZAfkdkQ92MsjRdsgoIF8P+z925NbhxZnmc/61NEVVlZZhYBEHcg
# DATA SSW1KYq6dJEUh6RK0yNxaAEgkBkigIAQQCazVVqTSl3T1Vtlre3ZNluzsd1tG5s125d9YKuKI+raD/sFkF9hPsme/znuHh6BSyKT
# DATA mUlSdFWRBAIRHn7348fd/7/gIQ4WI/BOAG+U2lGt1grJeqDivBH4MSLEtl17DFeMGIns1RFKnaytq6JuTQ6kfjlaoaMVOlrhWdEK
# DATA VxxqVprarGoZn6eNfxIT/zQsfMcqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELH
# DATA KnSsQscqdKxCxyp0rMLnhlVYK1WrtfYJWYVBp1sKGi8QqzCz8HxsUmGt5FVKxb385ubHpUa+0vAaNfp7t1Irf1zd9MpevexVGnub
# DATA m6lcapdalXY3i7GjsOpzMXbVGbKhnPQTgN9mGuBXq5QyBL9qMylrObaWEPyCZuC3Z8GJFh+wWUsFX65spoPfrCwM3SQzFXq1WFsS
# DATA eu1Eodsl0ix51Wpjr7rZp641X93cq26unNOlWRhho+TVSo3deq2WCaVda7da7bkoyuNjB6XdaOygNEELO1jv1JqNzpHYQb/b6tZT
# DATA 2MEO/d0pW9jBTr3WqBnsYKvdrraqFnawXKs2K2eOHTTb1CD8v7PSfH0Jt0/sW2/GLtLmeOZtZqBUU6+3AupuQj8n8ZsLMKyplbjy
# DATA DK0PC4szL8i43W2jURdIet5N5p5Xgh3g1eWPHSZbpyvnUE2bTsgUMXLTQV3xs4aKhQ1MR9beXKBHdLXsVZzn7ZXFlHTSyvB98l/q
# DATA jz3jXk4czGRrLpsnS8yWpUlme8IBBx1w0AEHHXDQAQcdcNABBx1w0AEHHXDQAQcdcPAlAw7afDdJtngxhJTGR8UR/Y1fNYsXysUc
# DATA zSzVT/tchBsyZdOYr2tySIYPuqGRXeBfwaVr9xFw4P1//7u3WcS3ThAMCx/SfwPQ1ijcK1vF1z5ce5+11PkcHS/UIBD6UYIo8JSH
# DATA IixhmcM3iIvXOsC9TMfzWzFC3DBP4RO/6x37KJukzgviMfzIwSXvf/zu/0VkZtK+XikXL8hVFvdE14AgNcrMIcTc2e6jzna7M90/
# DATA 9TPdxyWFPQ9nvTMutuWYsOtoGuaJgncD1d7WdpkLB3ump8NfnKORZ0EByx5mP20G2KwkwEkJYGl/rT6rf52pXVIR5DXdwOjavAHX
# DATA o+91Ivoh3ucz2rfghETVYimgXT8cFbw74ZjdT1rwXSqgCJdPhnI8WRVu6vi+n0gZDSHaGHX5LHIimpNRuJkp5wcBTGXfyO3AJjp/
# DATA pZtndArWakHOGHLGUNYYmulRneiNE705yox6PsRwbkl9ZaJFJzL4i4+illHEuW20G6gZhjsDRf5SGmoKHzmiYaENcYsubhYlidgH
# DATA fhXuUY3H4Q35LN8hOjRwQ/Zs7ZY5mikrg7/uQnUG/rFEycbmwbDvQlQ7HO5rNdwXJQX6JCrpY241i2Ff7HYUWWj+uPhe3p7LPctd
# DATA /vQiwLusvDgmd+XOEn6SzlUhrlxFq6DSFdtKgCt39yMRa4omEIzxIccikJU+WoqWSEQN99kLJbJMYh7SuLYHL/LfQp5l1E+rF4lK
# DATA Edl+UTLe+RCEodrhi0Z9lw1lfeZUGo2aHcwXdp4VgDYLb2KTJAk0OaalHDA2YEGZM4YesAShn45/deKSu71yyd2WA+Zipeuiuw5b
# DATA BB2hz2wAKo4dpf4dM+krGLI6jmIJpdFhKD6W9BG1byoCmaRuaz4jPIZqXxT3pr1grMACIxWXeBiNn77IUik7vzJLepNjltm7y2hl
# DATA ql+SMnsXAkTIx1ZEEbIBUSxNpNdRtKDZjjCyKHepE8fFqEvWiOFpdYN90ZzSg9tYJOFxpyzucEnvM/2NmSum0XHptybxwdOXVjpN
# DATA L0Bx3Vy5uG76ALfzYgb19QmPKt4VLX3TGKjX24E//EFwINZ+y4eClrcb9aVhYXIw4NBYo27gUUGNQAsDKge8KnbAd8OHgo9jaEJS
# DATA mFnht6cvtHTKzq3QklH4mGV2d3GZ6fFc9YqiHIhrSXmJPwL78DEMUBOKhRXYE0cMyyO31TjB3jhvm8u3y/gu6oQgQoZxTyxPHJvy
# DATA hhM+PMfiCQOgXU6h30vi/vyXSHnVErkZKOU6DB9j9ZMiXMr5oEAPMNKcxNoQob7I4+NdaAEHIkgoYEDVarh/45k1AoDZzUNZGGsj
# DATA BaUr+nen0GZmE3KiYjpfwtxTYUxeBj+bFYRztDlHW9bRZlcp52NzPrYTLjYu9MmdkeC0TMllpocREJUbNqZxsT1DqMEZkedSniy9
# DATA 9wT2Pm+yxvJTk/fN8ExY/X4E6CwJxXRX1qWEGncU6qy+IodtX3vLDLiL5wVq1956u38k4E4CSAB36rsFuJuLjSvJZQ2OK64MuZPd
# DATA PHAX4oMwxoSCDJVizquMA1E9kHgPdQgzPrtGkbFf2Nbu7WMhk/cXNYqLvXylEj9yN3iInqhjPUW/LHmsyo+9TXcf2M9Ui0vchAsR
# DATA ddo0xW5astTGLy6kznbd7e9SKN5HZHkOgoOCLfmsdJ2lE4BDaD/yStzS/JGCxekNa0OaJinTHavO1FlQnDC94oGbgjbueHFocN8i
# DATA Hnvl7tfq2vxite3MY8AlFVilXOR6Z7Vw6qMmGn6p9uS20zUVetNKhp1C0SrsObLwH0rXN6A49mSqyKrZw8kIoHdZ2I5i1k+1BLJX
# DATA gMj9RIznBCFHvUjQHvndsYWQu6Gv5Q9/P/3x8PPD3wEiN/3zLDruX+bi3+jLY3rqi8PPDj/HZY/+eUwXv+K/HwEcR1e+nT46/HuD
# DATA hHsyfawU0qHwNYR2Kg3ZDhP33Jv6bJn7nqkz3l/7e753rRPKWSwRvVf7Snj22x2FwaBDHQh/249GvY6x/uH5ngzFdwpXgrjOegdM
# DATA 143g0haKKDsNkgUK1fPgqeAhNbTOUoTc6xDQYK0Jj/8WnoTjyCUzAtMpnDdHbn7RnB1Mbpeiw+SCBE7N9VVfPwomd9UXSfCzAMrx
# DATA 5iuyHelfGhPEdYXRHA3GAeVWK7pTB8pJnvls5gzQucm8ykyntGGjJlN96aDIctEVhRf4aHhDv8vW9s7Ep0YxDqhveyOMH+Rg/dDT
# DATA V2+958XDQJEycPyd0qZUYSZsA8G1OF6BNje/ji42cea2wecFOzc/MQ4956yHM7IeNJbuxEbDS+FCPD+D4YzshZXMhWNaC+dnLEgl
# DATA nZcZxlB4PhvaWVDsrGwAaA6LxJ1gCA4VmTJmoDY5xLP5BdnSjvr9CbprLOC9gxlEmx0WLCkSU760A3vEHwXsoBDvHzIsVpvtaaSn
# DATA IuPr3XDEp2jjeGXCHUBasfLNapgYZcgeWYQj8XOoX7s0Vw75gAPvCLoRfUQjmsfJa1MGRt1xwbut4y0HFBQsLOsEnrFb5KyARpAZ
# DATA TQsmmSE/oIsD6eBdyuSwLd5jTvtA3DW8lzMYMEcHJ+TRugAiU1WCctUx7xzzzjHvzpB5t+LodaKDXcvM8nOfaZyGR/Wk8wwHwHMA
# DATA PAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwA8B8BzADwHwHMAPAfAcwC85waAVy5VOpXy
# DATA yQF4lRcKgDdvBXolCp7FiysnODo5jZbkeyOjUFprprKrWtts1IIMWa1cpgKoLiGrWa/ePPGrm+VWuV45+avL9RO/utJstKqdk7+6
# DATA Ujnxq+vlzUq1cfJXV4vPrKyrjWdW1rXqMyvreumZlXWqXW82zzPDU+36eK9+2gxPtevjvfppMzzVro/36qduXMVnVtapdn2+ZZ1q
# DATA 1+db1ql2fb5lbbfrcq1+nhlut+tjvvppM9xu18d89dNmuN2uj/nqp25cxWdW1na7Pueyttv1OZe13a7Puaztdl0pVc/VVNg88auf
# DATA NsPtdn3MVz9thtvt+pivfurGVXxmZW2363Mua7tdn3NZ2+36XMradj2Ui16lUd6t1Yt7jdrb9DXtdGi06rVqe+5j1WqDH6vUZx+r
# DATA wtHROI45piYgFly+VE8FWWpWKuXZmNSKNa9cq+2Wi/1KzSvulouZ3GjVglqrMRfJ3jwRTb2S0NTFn2PR1JtFP6jV0zT10malVK6l
# DATA aOoZvjpo6q1gs91NaOq1cr1ebRmaur/Z6vrFhKZeLdXa5eKZ09TZGZxv8SZ94+mUxXaNRU+8rU1xWNvPZIHoZilu3rKb3qjR4A2a
# DATA 2J7JTPTZ3Y51+FnlNXwQbLVtGXVrW8ZCoLsV6nLWuhSXclrWzLKLrhF8LGHX70T7lzbpR/wpeqoUPy3Qq/pwgS1Ygi3PBLc8D5MA
# DATA PbXVVO9fk2Ur8+twzu4Dtdara5hZBlB7QRNPdy5zoiC9vF1cDFu3S2qJO3xeXWMnN/vVHVTdQdUdVN1B1R1U3UHVHVTdQdUdVN1B
# DATA 1R1U3UHVXzKoemIxKu2G9Q1j31Gqvdui/ZEIf1wWYhV32Wwr9w4YVy6iIvl+1Am2BF1BF2WbLRp1ck1EJvKwQbbKtVq9xlcxyxPZ
# DATA tHhLs9F5aqwQ5+o3NEoNSEfE4IIYQ5htqymBh30FG0l+qcsLonEHIXNh4guqObeNQkxDdbBezNWrGzCOcFBl/eIHH6r/Lm394mf4
# DATA d8TB3Lu4k6NytTjtXLbeLJweqgJbn+z5g7DX8y+Vc8PehKb98aVKDpJxl2qffsBR4Wmsics9jae/M9nZCWIZF1mAzLu9feOSwca3
# DATA g7C3jjdcyGbPrwqlJtPk3wpfF2j96yz/k+jwZkKRAEQAhyb5CELz44ehQOVLhbIOEp2zYolgVBDBC2jqidAhv1DVGWjijSHPNyZz
# DATA WdcgURKCZIsC0nMmJBqydPW1ZeYUZ3DYXWDJfmImGpBIy8jT0tNJJd+4jJEFjquMRg7EPlQCoORiS95wjGUg+HkuLdDhdOqcTt1x
# DATA dOoyYi5Osc4p1s3R/FnMsnhelOy84QjtlDW00nEyUnbbaUm3nQmkcSHMtEi7TYEtBuDNhu1QBY35HauxarEqptFmJenSaK0ZOTpz
# DATA 3275yi0MTdS16IiLN1zLTf1Gxm2lmJaQr2ADR0yoBwYQqBss4+RZRX/MAvUSXAwtX0/GfD3VvQyxWGhNKbU5ILY860nGeULZiuIc
# DATA QBufkhLCuNYcQj7yF3U5OsFDQNRE1gs9lXmYRqpFSn2c7jeUXcRye4nSrRoadfrvGEPK04YUFOuA9xGlYpoPC/VE5VDIOhYF7zcY
# DATA OWceae9OoFus9ceUuVLweNKQGmgFDywAVPHU5lJU4cSiIOMSCn3Sc6OPZcxKiAgzqJheZc4SxMtyZFt18ZIjqlfnxmJyYxwNFduA
# DATA 60o0YjU5qJ/FkyFGaGw5hp4z1bV20LH6/7H/QOAKsArZnsHka3igClUPLv6+f5BYVDIASezhq/buBuzI1HFjsKtvmWIMIraHHK5b
# DATA 4XhZsvn9eNtHEWVaC4Ohz3WO5g064dfhQfEs216rAjINKq0XKDRUFu2iKGFha8glx1Jyfoe68NCQbZSgnE6AyNBp+JOeYCSCcpp1
# DATA w4BOP2llxlRjqp025VQ2UJ/Tiw7Y65uFrIky2E9f4CwZdZyB6gzU4xiozhx9eczRhWbmcy6sbC/wzyLMeik7VVoM/T3e5QEJtoqy
# DATA UJNHWK9HobCeV/nlF0tN9Cigg7WVQ3BzvEXmyqvUQWdbqj6Oltrk1SxmNnmpo2Z+j7/Nay+zx8Sk9bcjuKXkjQeDto6OUl+68u7M
# DATA KTP24JPNs0DI23qWv3C6MhAwvZFGa2W/rmzGXa08zfmjjTE22OaLNyurTMsDM69jMrRsScPgpMEe9qieLhjMV9rATJujloMvg6/I
# DATA 1oXXJyFq/qzetlSKGWLXkYSPgXpxjiIyCsh08VtkdSvAR6a94/SrNAVNAN6tXLnTF+A35aahIXNzYy1fXxGR99KzFpYBB/V9GETD
# DATA HrXQ93ndA3mRzD9YzUwRF0UmOaUTnjYcxz4qrga9GWsxi5TmKKvS09FVkz9j7GP2oMtTMdNkhoGdEDLjZCwJZimqq1KlvSRit0Zk
# DATA RLbHyyN2ldcbvBgW/4GOnrooM2m2wD0fVYnzCDm5P2LV7Gh/QFM2+insQw5dV9a5sbkqk73Z2LyEIsWOm+ys+JNa8dkq5/zMzs/8
# DATA 1Ab8wunC2fmZDU88y+MwWLXnEvN1HvxlvfJLP1x7OJR9O7wKTqZMEE1i7Ws9gmecBGP6PeuSAfg2jwIwl1YGGhuj/33uBhGxNMBY
# DATA 35Awls00IcsVVqvs+E057hcziNU6vEzz+OPie1HqbLax334Jo3g2ZbyWblKHb4yYUIb5+lvh60cipq1g0nmgL5p4Vo8qltoxONO8
# DATA 6q+gfxRVuYA9IdReKROWR9o8bmGn9ZWEN31UdCurxpY3ciQdWJ86Buo7MnHE7hwbNT7upDnj8t3EbtuLyWLSyzR2VFdgUl/TqGTu
# DATA IEYBr1loz/SLC6g2awXSAff8yYDmQ1gQiMdpRrVJfwdwGja7eI3AogyhZx+BzAyEtPQyBW8bl/dCsnfsRTK2hIKHbbWa4cl6hDrq
# DATA 0FXUTGzw8AVgcxBjwxrPOnjGJkYUr1UoQ2nkh4reBJa0P5SeOlOeiQNF9Y7JJpJUxlruEYPkmeUiJ8UueZTBMc3hMPEKWxbExEyr
# DATA ThQIPkrN/DxwovZRySgzGBnaHiu8jxmFjuZk/9RmTRYwexKHbXh5wshCZk//j8Mvpl8f/hFU6+l3h3+a/jB9dPilB3Y2/fCX6ZPD
# DATA L2fp2f88/XH6Pd33h+kPh1/S3dOv6eF/o3s/P/xTzqNPP9KTf57+ePg7ULQRtJC0P6e/n0yfMEf7M3rkX+kWkLS/8egu8Lr/RME+
# DATA oWAf4enpVxStb/hJCuIr+vsHYLkPP3N07ed/QkidWNQP8iDLCSJLc6e4r2pTMwUIr8fLwLxafkuNEL62aXOCBGPnFJlxw16geGGK
# DATA dkW930hD7ZkNlhitSynat/EQ9UGBQ2en5ntJ93De8GyrRM6OmK1qVWzN9PgCV8w4e3cr8JPu+nX6wpWxFdBYf5qobAqX2dWhHsnU
# DATA 1oqZSd1LyspeodBOnZR9dTeCTr0PiDmNqQNtv1IGs9tJESW5N6Fym9kDLj5fsliok9oLepcR113eJkX2XWx7qfxYekO9OeU49W+x
# DATA BZO0pmfFvj4y8g577Yb1pxzWNd76eKP5y+G5PceR/DQH8pXG8WMN4+cyiktNNElPdvs+06ZyFoBqk0bZHrooedx5K48Pl3NOdlJS
# DATA GnZYKsMf70oautgIuStLtrL6TNNzX8i0o92D8W4/KTBrL6Svc0MhizEUr0Kkvhl5JroC3tXMZY7NIPKk1cyH8xa8bf6RBbpjIROz
# DATA orMsYaleFQHF42hI1tauouCO/RYyTA7YifWQpMoAsim/2mEs+hQ6S9twRji+tONLO770GfKlVxpSVpqvrGj4no/tfhLT/RQsdweS
# DATA diBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IOnnBiRdLVf8
# DATA Wu2EIOlupVvs1l4gkLRZcV6JHm3nB1ystdpuvVjeq1SKb9P3v83mY1DbnIO3anqlZnW3Vq3vNYG3aqYfa5c6jU4p+1i/VK15ZXq0
# DATA UsyXGl65Qh+8SjNfrXoV+j/91sg3vWrFAzyrlK80+VoZt9e8yqZXKeFuXC56m161mS+X7LfyTsg026rSqfn14jy21Zy6UUN8Gnul
# DATA chbQ1qq3Sq32vFCqMzA+m5JWSSODJVwL4FVPqm8lTTIP/FqjNRPDcrn+9DEslypJDGuVU47h5uYpxLBZT2LYqJ9uDCuN8tPHsMJN
# DATA 4oxKuUqN5KljWK2Uz66Ua6Xm08ewVqydXSnXNkunEMNG85RL+TggPRmENEhPxjMLpLdZrZUqm2mQXhabx1f8LEiv29kMaglIr+7X
# DATA gkbTgPTajVaH5ugGpLdJ1nGleeYgPd7+mV9m3RcqGT7dp9ZDsyy6lEuo1EzPenQmsI0Fly3lPTY9rufLnWBnIxVyhtD3VkDjeujn
# DATA JO5Z53eFXd+y5M1wvuz6vQqZJ2urrqkVtPnO/tyKlXQE4+mNRynL3TgWcMRA+8KxMSx/zCWg6jwHNPvhrPCUF2wWz6dqU7o0UBiW
# DATA V6KB5ZX526FmXlFArMlmtWb5ZKLqxmCXMFnFtfbmYuheUsI5u0yWzCJma5tKrlWNlLN7eeHwVAC1fuE0Kimo481HHQTQQQAdBNBB
# DATA AB0E0EEAHQTQQQAdBNBBAB0E0EEAXzIIIOqCmihusXWa83HoMwcJ31GOZdiKlyU/+HTYltSWsPMft/BjHrXlMgci4hFbanhTXylu
# DATA HxRz5Vw1V6c+Muxme0h128aGftzcfZlfZyri+iAXgv820N3elnrC6vU2Lg+W5hIAcnrESuKn3iOj5MOtKw/1G6QnoyvKzn2oujP6
# DATA D/Q6e44xxNGx9Y1PUjl5mQ8Ba1uRM3Qjk6rB1hVKEB+/hDHK83Y0Pz4HhyQU5OSnwvxR0NwrKQjeBptz6Wnoh2vqvB86iqRWbtGo
# DATA yxKycsqY6qMw8G7LoWMkYUgdLGPuTMLGbPECufcz9fYNsfznl80RKRlHOzu9VEpyIbVz1CJJEgf6Ab7fM0WggIrRFtdKbfvHbeg8
# DATA IrkbuZ3UT2/RJIIqdkRDVkAZM2gfSKHxa+htxddKzeKlSqV4eaewQ/fCWPwNbthmo34dpxZyKkDZho7LG/ru4OEwGkCwze/d9vvD
# DATA u1H62WJp9tkLhWIdEaKEDKiI1ncQmP4id0NJLxzwyibuZA/UunyKhuvzQmxQMUkB3pLMZMFEwB3X8eFCiZmNUddrcpFy4vUvv2xe
# DATA 5rq4ZU1kUNK5ShErcAKAhBsl4rr2qZqTsDK+RjDq6vBJUvcvq6rxqW4DPAUeY7sRF+H21a39cEATqwKfKud6+XD829+qi/tB60E4
# DATA tn+S3uLqxniXxmnv2mjEtVuOpFvjNNLHWST14Le/xXxw+ypFyN/3Q5r9cfahn+5jnJxTmY/ZiqKh1Yikf5SGcvlTnu3beSJlJHFO
# DATA mxezx9dF9EgUeCB9KKe4W4EX0DRNt03qd8xUdk5Xx+fjwh5N61KdHorMPCZD3oYVSwpUlcKcILHGT4+YoKznOGtfk1YvwYhPzRyq
# DATA dVo2TstmnpZN+qC1E7VxojaritosFCA/K7Gba1h34dEVahODwJZt0cI3z05A7TxUxsUUoMt38cFbR3HEF/vhYDIOjtKx1s+azslc
# DATA MJLLSjU8Kwkte0OUJnR5mYS1PuZL0ebjulCMP0CXxfkdsXAGlQ4voO3KShMXJwUg96czxqwnWTlhfmSzlJesJW94ClTkO9MZoT04
# DATA SVaYW5Ok84OljLr18neVVn9XKZ3NeLB8rHeVV39XOfUufrByrHdVVn9XJfUufrB6rHdVV39XdUZq/UrtWO+qrf6uWupd/GD9WO+q
# DATA r/6ueupd/GDjWO9qrP6uxoz++5WmeZfWVzFteKG6uj19/QmIqeuhQpAuWonIGm2o73sgaCUcnaGpnHRgMkJi9gBsMk/S+5BaGqW6
# DATA PAmhlPMqOa/Gw1EDFK1gwEKqHnYQcNACFO4bEpgVMRqo5vtPPfSvDDOwZL+Mtz1RlaJhCvMGrQiGQRBhitV4fD2wFaTMX3wxIQdt
# DATA dVOn5VMnN1P6ac6UjgtifeayoLy5K9nndRYIT0t+85S5nbZ46VxY50KcLGsI8slD01KFiwKZ8SVY2edAHPUFEQtcUd7cS3YOauNK
# DATA vJZ6viwndih3aDINFU2oJBlDa1sptPojFrmCY5SMITxNZhXZV8w/5bUXEWsdyjSet3ZBhxHzdN7VlMMDqqAS5Uae0FMhhT16xx52
# DATA IgoVaAdsMpafpJczIwe6fFoM/fi5CLOPNSMz2rHnKZn+bCylVLV0xpIzluYZS6muyrmZX3o380Ij69lrquuaT9XZZ1npA3gABnQf
# DATA b0ZKNNaHIzRNyABnGtnOhObH7GoeBUoDe0bem5qLUQC3lMEjNcXnOpRxLKeshlkRdXMfjau6GfOIRKVr9JUxbEbdrufvRWGHVz8H
# DATA URizS3ykNbWlO0jA40nCtKJbwbtDQ7TXpdBERD3mdVI5SozBtydxiXn/IgI5MFrg1LNMWjE1+slYDDeWkQPzu6OJcIhxwbuhdLa9
# DATA ftgeRcNddsAofFzgt9ktj+cpB6Bbje5rvic+cff4bGsMlBq8zpQ7wVjMiDiRfu5F2MgyBs1XNuANfYYaWt2eBugVvG1kJgUdDocK
# DATA vI0g2CV32cPCNq4yetuXu+wy93BGAn3xALmj0e+Sbk6Vt09v45XxJcm76cOuEW7xTmRU53GVzS0qCZjFUsAaO0+lLpV8HPWj0Sja
# DATA V/reUv15lVwXDVd9TzJxgH2d0aQNDRjGoIvvKjnEm6RNGO4Gmk5FhYFPUZaXpedNludnzxgWeGYAOT2y6HgKEsBaFAtUKcJHGKTG
# DATA PITtkslgG5bUJjFpYFMvFtOQbu/ihDqaghkHpToAhyiYALzoQcDwedQ8ysa+FBKTp8my3EFV7oFET5GZDDAwY00pGsbZRIo9dRQp
# DATA 6HWp57xyhfhIjkouTLIeYUSbB5vURlqr181rxzGGuYVe5WVO5PRCiSmFJZmX+JX5lU/52pK8ln6RZmUa3+m+hpdLpNEkLCxhFnAj
# DATA Ot238YLJbS5ZU1nH6HSsThgt5XTfyksn2Pe9uGGmX3hx0ntKX/xPd/aTIC7pbZ0oGsU23/Jfpj8e/h5AysM/MnfycyZcfnb45fS/
# DATA gyg5fTJ9PAu4/BcmWAJP+Zk3/Rb/MMzy2+mTw997jL787PAP9OcLIVyqgOlFjLX8gQJ/PP1e0ysZjEm3fQvK5ePDf6DfvnEIy+d/
# DATA 3nZHZlqjCEYSm8JYNIomO7tjZuSIzLQaXnvhGOoacorYTMQmA227kCmFUc9neKsM+GzBxDJzAwYFZqHPZ1CX8ivv8I4L6gvDnvcR
# DATA WYxsRDmSZTKH073AeWMs5xbM2QEtuV7G1vxRV1NBHqVvRmU1t95SNRfD22nSLMlYZSEFtYYpe02oSQwdyXKF0jp1kOW22lrVo+Zx
# DATA kN/3ew8SUhOZ1eDtAP+jkgVbt+3juBGNsiPIsym8jt/BCGGgUYMgICMfC/BULw94bqAoSDg/P5whWR5R8xabJfOa07MiWh6RCMez
# DATA dGP804zxGmZ50qH9pXDNntuwfjaj+kqD+nHG9HMY0qVezskBM6A/w/ZzFoTLOUn1aB5Kn5g956tlUkkuYpnjdU4f2R62Mc4ixZzc
# DATA eVHmjc/q4VEkoEDpm1pYN+f4+hy3QQq1twrcMuXoRpRUMoz2J7u7sdXP26c5NtaARfkgFiqg916cmFAy8pPlhl3eXYpZCENA0ITh
# DATA gNeWDO0S1k4oL1CeYRQaL2RtW2hI5VvtBDRG9kMyG/Z3A46F77FpwhvsuoGjXTrapaNdniHtcpUhZqUpzUo28Xmb9yex7p/auHfI
# DATA S4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x8bpCX5WrV
# DATA r9VPirxsBput7guEvJyz8nxc+GW17FXrdY/yzStVir1SseaVGsXr1UbTazR75WbZqzQzXEu6tzWLw+yXNitemTK6Vso36e9Nb7Oe
# DATA r9bypVK+TOHX/vZGtURhN2u9eiVfKja8ZsMrlRv5Gt1SzVfo9Zv5ci1faWTKpBY0Wp1ZPmCFot34uFQr5mtFr9wsecVxtdL0inuN
# DATA 5tvVSjqMervZaZRnw2hWvVq1+HG+XGzkmxSpcjVforygGNUQ03yzcQRZ00RuhqNXasrr2uEIs6U2F3+dI+G1uWhLUnNHAipMxbdT
# DATA a1ar1RPQ8rj+alqeNAWLlteq14JKaQVaXr0TpGh5QaNT22wltLxatw7b2tDyKq1qs5zQ8pqNaqkUnDktj6t9frlhwN79jG+aigpn
# DATA Lz+1AtC2QYqdJomexbmpfJ31/+EPtfDLR60hzDd2FsHfrFgeTeGzIXvy4PEge9VZyF4SzDEge9oBuTCP7JxWGaowdqr+2R6jMttp
# DATA bAyYQWzBNgI9dqsFruJi9l2Srzk7q5aYE0fkhCHaOficg885+JyDzzn4nIPPOficg885+JyDzzn4nIPPvUTwOU4bTiPktc1DaXxt
# DATA 2YDGCCLJIZYbmtufeoY+ht6gt3VlvTfDd1Ip3tAd2WsUzMN7Mq35wMOHjQu9dCXjmr9R+CgKBxTAh/Qf+FCXjXn54Zo+dp7EpTB+
# DATA iHz9cO2NmRPpKoAL+KxJUVfNDgUdqgY/abaSUwh3B6uXHKx2B6pfkgPVx9ULf7YHrdkvmbjSZnFEvZQW5k4UdXC22GM/oTlmyyQJ
# DATA BLJEZ/tZn89+Ec4o8t+nrNU+7yD5aau2zz+XP1e/fYVj8omf1uiHByJQh9LWspOqchiNmbsBRSGO+gGEYPhorVQ1PgGv3G9MZBHd
# DATA wPT58uTkeA4yyGRrJo2d54zQM4UHOOp24ZjWB5pF9xCBS1XjV2QPnx9HRHymmsiBXD+xTp6NWM2zOM1qnncGlTOo5qjRJRXKCdY4
# DATA wZqT2lEL7bWzEbLhPl03A7KkRLuCNTB2o3G0M/KHu5ao+DPTTTsFgCWNy28oGRpr9DqmZrEYAwjkFAWL1divB/O+P+TMscb8ecq3
# DATA p6Ja/D7Le0vfSLURCino+c5AuPhN2Or8ooEXPKR89OLBqcsHs2jxO4N40vPHol5+oJK3j4QOqRPvetTf9XpnIVs8YU2lsebOTFgD
# DATA PNMaTve9NVGehsR3xxMRej3O0fB3uu9i+uOtYBSzFBNWqphvL7IwzDbK+yEZ8JMhNcjglNWoG0knmrGgqTh98GCFASIG9ylLRGdY
# DATA k8m0TIJMOybpIa0V5PUPjPkhvY3BUSYASFtR3SwHJYrymBzY9Uc1oYNEfUoGNDlxFC+QlmoDsKh1pSxdKqgCsbiUdwcC38HAY/DK
# DATA oE0FpeWnuop6QHmfMwpZkeqdtaQpFp4OtFYSz4hGk1YLIvlcLswkRjWJeowvlnFANI5GEwh5eTrTjI6Xcm8G8gKz2O0r3dTVUI8/
# DATA nemHZVC4CYibgMxMQNIWppuCuClIegqycGLxrLU0Fa+DmRa7/pBhwz5mGLY4dhwo3T0tBZkRi2TUjlaHVOijQCYzls7j2BaAxFjZ
# DATA 2wc/aSK4kKzEo7TYCTVl6ruoFPaCOUqPq6ptcmqHV97kpc0k3q2DZHbE3OXWJOx1jBafigw7GmfdxurwqAWg1+htWe1nYBU+KQtL
# DATA WUD6xwSeba6wisAus2K4Z5PFWdm9QkO3lZQ0BFy912whgFWqPr8qGyPUy607TM9qP/VqxD1sYvhhDR5jLDUbdR/blpFy5GZvpwmq
# DATA OszwFn9afGe7F/ZbHFF8WHwfdcwRNmXRndfkY3LvRUnblQymXNuashpvm5oYUZYYmqnSxWZgafbqjHRiOfujjpme8uYHmaiqfEzn
# DATA QwbMxTupTXcgOwtkYjvh26veg75JRjbeJlOhHFm5cjtkVlMnYJgQtdaKeAn6UTzuHSj4JX6ClWik2HmtRnhd4WAsQ2AgcpjYJRnv
# DATA RkpP1BfouRaPZaD4wEjNUsvlabF2byspTA+WmbIO1UGt883A+jEy8H2aE/fYdx+O2jRdTLIQc1TqGIDisjs6NcuBp4S6hY/UFh3q
# DATA ya7yKgHbxry3EmZ7P2rhEer9AqnTVBQPYlk0UxQwLovTyC6rlRwzvzaX5pdpcpJh70Lyk9rFTmCyCt4EviedRwbBJRlZ8N6nMTPn
# DATA sUpeSEbYgfI/KYgYdedCiZPdKuIO05x5GjYY4xZ0TiOrTMdzzIxqLM0o1YtJNr0NP46Y8+HAqlX8aqoQ+xTLmB0x/qinVk+1bwZO
# DATA BGyD86FVKytdPM3Gz/D+7Rwk/sIAS4DYky/kXADHuM/jdghJXUZX8E3PtE3WjtEmrwNEhz6N2l2eEp0XyJWpbfZlam5CrVMZaa28
# DATA BX58gMU9TYSjR8jmF+lhzk+xRWJgvKwZ+bOsYKXy6jXsekRFTGNkLzhgN0FSx3r0S2LhKO+uOPxodktNkD1xibGGDKEenh1WehFV
# DATA LYqKtQV1YJzIiVQdJWtFXFCgEY7C9tx8Sw/EsrfOHojNFcmGKzcjvQtOK0+zCaZ2p8EpokpSUaJ1fheOYoj9VBwQCUtsGIyB5rVR
# DATA Yv9NQGLe9OvpI4+xXqB/fX/4n6aPpt9Pn8xixP6f6ePpt/npdwCAHf4OALJ/Ay7s8HO6/pfpD/T3V/T3j9M/T3/0Dr+Q0BH0E0DH
# DATA Hk2/O/zT9NvDL+jfL/EmsMjozRTGIwrhkQaTfT995GhiLwAFeiArP9jH01Yq9QkFehhEQ+Y3MmCdh3Zqe2IgdiIon7O3EQON5ZJW
# DATA Yrh8F/roRFid30A9SCgS8uw8XkoVewvmErPbBwcOJ2b7UFRHcN40sXSBnC1GLBxYa7jXdC3Vv8yyxAZjHAI0fSy+ykgXjE6TJ+aP
# DATA BVGw68c0nMKCJUs36nYdTmzVUjt1pthVv9fGqmMgC2AHCaDa7/NOe14C6fE6idfFVMJjLhzL/ZlVDpB0+/2AJ78YS3gdMfzbgOkb
# DATA XicMxnMwYkdWusXWSaotPTuG2JEpcBwxN7qfxuiueWLHHtRfikWR8xrQT3k8X3kx5Fij+TkN5lIj7TxItls9+6ZzFigxO63iGFY7
# DATA OHYjeg6LD+mEIgUmlrqwsEi0JOnvgMHeG8ZCVeKkjf34gdqrggiEA5wcwzE+lSWrocQAMJKheg+8LgVr6iRkJ6k2Mqy3tU0A+FSE
# DATA jXawCbC2FZKBMMcumEB3IRzPsweUNcDgI9gBWL2KH1BgJh4hnONcm6h+9bBLG3vIJuNRKGUWDdrBaBA7jpjjiDmO2BlzxFYaaVY8
# DATA gbGicXxuRv7JfI+nYOI7mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5mpijiTmamKOJOZqYo4k5
# DATA mpijiTmamKOJPT80sXatPEu6WpUm1u1Wg+YLRBOzl52PixEr1SpeZbPxcb5SzJcofxqVfKlW7+WrwGqVPi6VKvmaV6qWvVKx7DXK
# DATA +YaHu3BHqQkMWDrrOt3NzUZ3hjAGwFe1uOmV6R3VhlfdzG/ShbLXrCPImlcDxssrIexNvK6ymQ62Vm92mt05YK5K0QJzlTdrBsxV
# DATA KqbrQ6vaqAZzAqhVrQAqFtmrOVslqvPIYOXGcZ+38qVSaXgVyodyzWvm6a9SqV+uliiPPGRukbN4cULsUqQ7q7Xabq3RzJDOzAMz
# DATA pLP6CThl3DIMp4wbmcUpo3rUaPgrcMr8biXFKeuWO4123eKUbda7jYRT1mm2q61qwikrN+uVeuPMOWXDYHwkpQzji75vBcyX5Sir
# DATA sJus0OTlMQxpG7MkMBOyxpylZrrV2i+9Gv0p19jpmEJzSY5KCCrCqznVVKqMY61spruZt5er7AtkN17GthHP0xKEl05XLhW/JUN4
# DATA 6jbtAnPILofscsguh+xyyC6H7HLILofscsguh+xyyC6H7HrJkF3K4rA4XB3/IN664Y93C91eRBMbmH0fruEwFqX+VzBpLqprfD4K
# DATA F+UrTbNgqFKrYevzw7XtIU3wHsJFGfQOKDcuIOgLlCvdiciF8fGwrqVzpc5a8SoSSFlAaunDXL46nAUNMgQpx258PqSNAyrmDJbo
# DATA /TnKljt2fNxjx+648U/1uPFJ8FrPwTFkdt9pf9dyypYIWJl4zz2qPIev9bwcXn6hzvCdBXArfdz6lElbmcpwUsSW5UhNDpGrnE6w
# DATA IJBnFAF5pbrC2bVbufImT/BZV07r0HH1gVDoQOnNyUFYU332fXqiFe3jtHOwM+lBvk/LzvUhJxp1oYbfmYy4gvqjvpa+V2fi+d06
# DATA AttkW4dk/PK2WR0FTQmj7OlikbTFWpxj+Ik83pwilgmWWnucNujZcVvAicpWgBd3yCabjFpGePIlOeppheHsKmdXLRFrsyuX03Vx
# DATA ui7HNaiW4LbORu/l14NoH92/KA60/B3RWIPkhhrYSucvJ3YKdC1egVA7QPS1lDY8T/Tp6nsD6C0ESobFuMW89Qc7GxkS0IDXgRLQ
# DATA jgrCdFP6ewqHRImmLhl6Mv2Q5W2LBfTZ1LPIlhwxjrCXM/lxgZy9+CEA9LEFW4bY4kqD/fqR8dXPJ/2qvpBAuJrFeXG2Y4ztOnaU
# DATA l0SYPSVMaYK7OtGxQUYdEVf1qImq/p7ChS2NZ2lJLDMEJbW+hNaqnC6iRs5V3aIkoVJdeVX2mqp4qjVGW8s3uSS9S7gnKaDxVzFb
# DATA L0oQT0eBsphNVvu2hY+UPr1CvPho9kYf8BpcT3YD5gbNWinBw1BUXHi4Q4+jXVAfT6gXglZ5PNnZCdgDDWAEr0yoDiIaAWMBqBKr
# DATA SmMU5kAHAFT0NI1LGGjsG1ftDgIqZMpP2B9PRQM9GCgE+zuGEQsFKhinsYzknbDL0ilj0R9iZWdPbeUNTHxEjh7SRByNOepEiSQR
# DATA yyrD04jIeP6Q6hwGuFXZTj8RYzc1gjlz15m7C83dGdPGWbzO4l1swj4nCodXWX0PmsVdDDLhgGXM5vOdNF82kQIcBf2QER25Rap7
# DATA bwpTcGa4YWGznUnYAc4wGRgpNGqvnQkAhDy8ZU3gNDRhRuDQ3EfjumGaat8TD/XvMScA49kooqHDH+sxl+3wPjXwCUwoZQf4O6NA
# DATA 4ytnh0ylf0ghdWioNsmBq2pm4GRpQIjLsOcoYE04zx+jQlOEL9vUdk2GDB7y9ii8IwTUgHJ9wYxAJN6iPd7fpBicmp871AwvbOQU
# DATA UMjDYNQOsd8xBUGVDOeCYdE+S6hQeckK3lvgbHE3yt40hnbtwubiuxhgAmIl3HXXgzH3s5wMmDb+OONvw8E1E1mPDzeAfbIsjdta
# DATA jtL09zqR72PWptk7qu+HymRONPc0mAiPYP2RCroX55iOERtqpza6xEy6icDQUx7ABFMbLXlkGfGQ1IKlHXTCti8lqPCZyMqZmm5h
# DATA zoKHNOb1Dpal8iYfKTbmF+NLdDq3eaenOiQyGeXgSWaF8b4ufp4+KlJOCPiJMl8HUOJT4p8WI42TlFaqLHh3guABU0LglmWeB/KS
# DATA b1XVQitWpvgy7D8VbgjUFuEg1o5iP+ZJrb8ziOIwniFzsCF2lM733Yg6Js7PpAviVnNsUjT7tPUYdCqcaMvNrRoD3NvsxD4DMvQN
# DATA VF+9D4aaq4+qK/rveppyBpToqylnOdoslbfQZc+AFH09HPOsbETdFoQgBQqpmDXcc4rA5BnAom/15J3oIDm1SePiaVbnDEDR29QB
# DATA 6RaPXqpj9HW5SOEtGnVOmZ38U5+/WVwcemoc21ic/wIIzvSH6aPD301/OPzj9LF3+BkQNfT1MV1+cvjlLBnnXxh1868MtUnfPf2G
# DATA KTke/fT59Kvp48N/UKH8I7g4dO3Hw9/jCXrVl/TL9/TCb7zDv0+RdiyYjkPjvABkYQazGe1aYWTB8wukR062oQoXuMvd1j6g3PvK
# DATA otoJWDH4ARzOghMea1YiQ0Z5EAVDcKe3nIBzPfC7/BaHv0nNMbm9nzf9xiqMs0PfSNKSbpHrTpfnYdlbMXKYG3mqN9o9GO/2TxN3
# DATA w5tsadqzixrf4RkBkHu8FRO3O+zNkSV26rwbTHKjFuaYXM+0xxo7RdR0mPuXnj/qq6WpZPIZxuKKntlDLfrpbNvKXIJKi3oxTOvI
# DATA dIGDewZ/s7z+LTY+knb0rLA3y2PuiDdu0D7GoK3BNscbq18OX/D5jNOnOUyvNEqvPkif/Rgt1c8k2gzI59cWzoJUY9IjhOQ4mxC9
# DATA /yLZxMD2xG7U1zAYq0xkpksDGgY7v8MJZQq6IVLEirHcjiYjYVMk46tOuBxlp5cgrzj41bg1aoqfGoN941zXo7cZt2O6sTPpBXpL
# DATA JC9hwavoxcOgHQZxzsQ/YRcrR2svFNdrQJ2t3w3GBylXoEoH43QZE80o4LYkKp0gB6hxgBoHqDl9QM3RA8dKc45V7Nfzsb9PYn4/
# DATA rfXtYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G42A0DkbjYDQORuNgNA5G8/zA
# DATA aCrVoNI5KYym1K29UDAas9x8XBJNpdz0KtXiLuNnylWvVK28XamV09nR7jaLtVn+SZUSUKk2flMqV7L8k2qtXW3O459wKaWDqWxu
# DATA euVq+d+VNsteuVykPw1vs/Rxqdb0ml6pUfZKtRK9q+KVNysfl0v1fKlCZQhiTjVfqtMtefpGN1XpphI9UP135U16tOxVKIRK8+MS
# DATA vMhVr0r3VOqpdFWD5ma9OAuIkQjlyYTPl0rNfqlK+YIX1YvA82TS2t7sbPrteWlV6BkqxZDMD8WuqRZrCbumulm0KnBVvhzMqc2d
# DATA dlBvd0/AjuGKbNgx3CYsdky13PBrlSPZMa1up1tPsWMoPs12y2LHVOqbHJCwY6iT2PQDix1Tq7Uq1TNnx/SoFRwJj4HT6NPkVkN5
# DATA sTguKnWzjj127pXp3+YvbXO7weZDEuTRSBqbN8Ob7WRv8bxYGNdVYc76KVlYHpYqvbr8SYXmKYvGAGV4FDW9f4pcI0WcSTGFCcvI
# DATA q8kf4xqVZDdhXNn+nJK1xqOCaFCGleiP+ldbmGy98oC4kFazQlmmsy49x56bEQsDclAbB7VxUBsHtXFQGwe1cVAbB7VxUBsHtXFQ
# DATA Gwe1ecmgNtog1NI+axuvLRvNGH6je30+daEey6EPnNu1eiplVqXauhLq3muLTeKNy2jnH65dTdS8cFjFknMZUA4rTRdMX9PMGnPy
# DATA wZ0bdueGrZMv7vSwOz181OnhhVqTZ3Kq+HXUXCjNJYGbk8XPVH/iFPTSoTWHN+8HwQM+4Sht9oRac8nYcnpqc0HQU6rcLVkloQzR
# DATA 6oPK0X0GsnP6vLECtw2pVDsjaM95NEcKegdnoDn3zgCHmsfSw8ZKKRv2cjcRqD4D8bm77PpSaSQTRPXmVCdo7MhD/bpzBrpzt+Uo
# DATA MXyAZMqpJBu4wJmUK2vP3cRZa98I0KHlyQgHk4XMS+yFmoyCU1afUx4YIx2faDKmlAGSw606IebULGUYuoBxqgexJOoTUXiRgIeE
# DATA auawPvdGhURdszM60BmdoBr83j64hf2AJeRxCxaqyNDo9Qre9bBrmkMOuIfebFtUKqoDRGXk7dKPowALVr0DeZK7l30/luhoopBS
# DATA q+U6KCrvaGzw5op2NU0qsMS+pwKg1kHRlPqyC9/gSJ2Ih04mPdqlIWWRZIDOFX3cn7rJAU6+8zYDGk9YCoBG6qzET2akuh3gOKA6
# DATA xS2TVrlDxp2jZeNf8JPHDjnp7PfEfncW+0/OYj8uUvIZ6gDxYr5ZiF7OkXwzZPlzBUeB6PnA4728SyCS5ywf9NzLaZwFHzIROTpt
# DATA OKQtB3VSMqS1SUFPm27jWJWpDjLxY+EUJTxVzhQkdjVIKardjSA2vj6Sh0EDwBY6DW3c9nqTfjiIJjRFNDbRgCp5BBGbYdDrQdod
# DATA Y+iuUlwn+2tQ8N5tidw+GSbYdA0tpV0ySRXmgHk2+u12NN6CgcZ3cWJ0LG7CLqIgKHZUeanWWGYXm3x8fiTgbQgHMbTU/Zgl1KWF
# DATA aI3nPiSsR8vez25oL/Xut6QFxWRexrwUXfBuRPFY238iLsTsHx3ry8ggaV9gL0H5hvpr2AYQtqduhKo6y4ZkY/JTF4mxegZnqzlb
# DATA zR4ZnLP15XW2LmZOPksJxxu8WKnrsxJg46PXFpQS0noMR9iDdpu0n8R5k2M3AgMm2YmmHYcF71YiBohTOKLSZtA+XIbsNPAt/UD2
# DATA abLvoBu2vZim+23jWWnxVrJEM1A0F1fUgOQUi+Mjafyy1oeYDPzRSPOE+HAJ3gOvzxwjUZ1xnKVdqnVuVFL+pPxkypOlf0yAiOYK
# DATA 5ziwIwGHI08r91PU61kpmEuANIvnXE3k86uyJUC93LrDdJT2U69G3GEm7jusPmPE7PX00mgIf2ikrLns7WQ3cKuK9hffs8NmDyOz
# DATA +NPiO1tsp7FG9kisFH3nRUlVkg8yHmtvoaxA234+DA1LXIVLbUbL8+mPOsYJzwv+4o5XOWjlQAYkxTuDTeuXpXSuQqMJ58S2SUA2
# DATA xpKXQzbYrkLEMRxByBT1PjFbYa/llSZnTiRG85iZaQ1SGsb6USdgP/4Y9iwMP23BCUrJdibCAWmkOgMWGtJG9tj7WxpwC7Z/dUVf
# DATA qme2ybGlkU6KyRotYQbAK5a7uRHRM5bTNWvLHqt4ksp3zBK6s7iEdDWWQrozZB9suoSoGXNHIh53YF+glblL9o+4QX1P6rqy+i12
# DATA oFkDwfOyCiJSqxHURzHlQOliB6OyUp6+bOwUPP8Fc2vVgrnlj3osKuv3+rpg7kRdhrEOaFRjzdR9TPJoBN1Jz80K3vZeFGJmTHlv
# DATA 3Po52/XNpTKk/gWTs46aJWJ6+NTlYUf83Moj6XuPWR5/vbg8dC8u5fHXZLDMdGSTdnvSYzVZLAKqk4SqcejJqmLpUS/FKwk4j01D
# DATA RsF7m1rXQY6KkMyQKOyJynGfe7Go3xf5ZzIu+sISo59C5KBZL376gkpS9PwX0+1Vi+n2pNXK9mevs4i16s2CwUfRQdKDaTGugvd+
# DATA SNPdzoQ6+h1ZijLyyXpVKLHwwNSmvGr7E6HjPXVZ2NF+/juxN1ftxF4PRx3eMTCAA4gax8BqPLuieL076YedPBYKWWJclQePOjEb
# DATA 9pAWGsMyf9/XXOpknd/m7aGETW9HIZHxpLZNQAsZ7qGnLqfZBJ2otNL2n2xjtO0/c0Xy/srNSG841BrcYvKLxc1L/wy19GnGguzQ
# DATA pawWTs+GifZCe7wSFlq8GwUpFNr/Nf3Xwy+mXx3+CawyYMzo8+fTx9O/TH+gv79iPNo3HsPOnky/O/zTLBjtvzBG7dH0O3r2zx79
# DATA xQFOn+QoxOnX9I3RZ/S/H6ePzUtskhrd9P30MT4pjtpfQEXD++W9P07/7fCPjor2AkC5zTYH3vIajfc1dtWQuSFeLOTVHM+MeJtV
# DATA ABNPswAADYU7gWVkqAMQOAM60CHoBoroSvV4NOY9Y3iuK0tYxikAT8dSchqU5dEUxM53+DTb18ddxHnT07IFcnYINRot/F60kyC+
# DATA eIchvzzL4b7YDZNu+s1wbOE7To+hBlNandtADY1kBOdscPi0o0vr1PlpNwQD7rXIuMCOLpr379K4Y6aXOW1kxREOQyEjYcgimeju
# DATA 1J5WzG8UafwhVFKCpHNina8c2VSyHDkK2LPIhFl9TKBPRSR4DQxW4xm22vJ6udiIybSyZwVYWx59B1hz4/8pj/8awnaCYf+lWN47
# DATA nyH/1Ef8lQb8Y4z3Zz/cS0VMJ92M8s9X8zkLbls64TxIcoYY6JhJdesAIeXkDONoIq+SuI4F6BT3fSx8maU3T/qlVhDDpRWMsDTJ
# DATA iaaBOjm2oKLXCbuG7UbJPvAUyWRFZttImWu8rQZHVsigYL9E0H6AsUmhybiOCfeKTw3zTiChzYUx76GKx0Lj4qXZIB6LqYB8SSyH
# DATA y4piBnrWeEIh9P3BpIvPI9tIUJ5X+AnYphkd5KOBQ7Y5ZJtDtp0hsm2F0WWlic4qJvE52vUnMeuf1qp34DYHbnPgNgduc+A2B25z
# DATA 4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgduc+A2B25z4DYHbnPgNgdue27AbaVapV0pnhTcVuvWg+4LBG5L
# DATA rzkfl95GtqpXqTY/rtfylbrXrORLlXKP/imXvWbNKxXpl4pXKtOner5c6dU3vVrd2yx65cbHlSpd9So1r1p+u1Ta/DjfzFcaXrmU
# DATA r2WyNNjsljutDPSs1KjWK9V50LPN2ZIrF71qsbZba5T3KvW36Wv6BSasNIWtTCko12teo5QvNfv5asOrNr1GMV9q0JeqV6179SZ9
# DATA WTlipcpMzGolQOIaH+crVKh55EX9BgWA2PYqdCFFi+OdnOmXBd1GfQHmTlXgdjjiE3YPpdKXE/RbqcEgOVY1qKdbgAmWAoBh48nT
# DATA RWStJw83m+lq3+3yd93/shwqi79WmlRvKIxjYuO4GWlsnLRICxsX1JrVWi2NjaObquV6ChuXAckJNm6zs5lg46rteq3WSLBxnXa7
# DATA 1U2wcZudymYxOHNsHNrf0di4ijYKxCTQzyzgxyGZGf9i7Zdelf5U6E+99ks7iAwv7p0+TSXGOWwFRny9m6zYQV/tmNvTpFqxeDnr
# DATA zBN3T665t5/jVbIFK2IqGoBXDT9ZdamgULXywquM0sF4ej9FyiAx8yXsqtYuPu3lTDPtVCaV6U+ppk1+9hWFY7Kw2imQnfZhU79c
# DATA nsHPFRfz5Uzu5+wcWGKKHJFAthIcR85x5BxHznHkHEfOceQcR85x5BxHznHkHEfOceReMo6csjjSHUA4oPC3YO99uCZtjhJ+Qb5D
# DATA EYazgU3MD9fu+iOo0PIjntyM5nWBL1C1eBOb6dZLGxcoN9r9wof032DbOiV+7b30MTx++IY/3i3wDH2dw/lVqVBDCMnxvjmHxhPl
# DATA W0hxmW5fo+aSYyvuELU7RL3KIWr7aJM7S+3OUi/RS362Z6zlaHBOn/Wdc9L6tjkXKHUkl1ZWM4d65cCqEmThs8Swo/eVDrOc5A1Y
# DATA ZT85PDn0DzCZlsOT0FoZWCcnV9ZAflNUj1vCiOqAQIVX+6ZDR0fgdI9X0T1u+/HEV7Jp+LT4TnSplLW49X35uPhe6mA7UcQZ/a58
# DATA fBEUkJO8OKYI4tXFIog6V0UEkYyy0UEHOkT+YM+PEwVEnJyk5gUF8XbEbpPJcIhzz9hogMNo3khkIWPgOeQwO3vBqKkFBY9adYij
# DATA wxkdHR4PO6ODnBf48QE3lKfXPcyk4dwkKq36d3qKoaYmK51q2A6jCczIpGzak3iXam7AIrk4gy5HqH2Rq2YzJzEiYFXCLhEMAwpq
# DATA F9w7dBGJMrXSc+Dj4RPUD/hLW5p58lTq1EkCXoCCeX/lgrlNVT0Pt8oBNMAt5VA+2JyjEhkG3Hq42egGwiAZFBz1R2g4WjcU5wih
# DATA WAXF8GDItiEy3FLTEMEBrG3J+Bb2dqMJS48+vb5rKinnVkon7tyur9q53QixcwYaHpORpYxMExSa82FX4Dga6qbTDUd9iJNOhp4q
# DATA mGjEEmz8q6iX7FOiRlFLurtRgK+sGzYZ7JJRBXUDW8bjaYokFfNzKxFrkDxmkdxdXCRmuJUyuTvyw57opfhk1phCoe9jGCew3yLJ
# DATA 4Q5Ne2DkoWoaGubIV81BaVYDJqyVZhIliUTsTURYegei9vbUBZOO/vPfVu6s2lbelzkpTVDDIVVhUzCo3bCcaeouW4RgWPMwztNR
# DATA qHoMYx7vMc0HjxYbcxUyKxbNcCUSPmZRa5QuPKdPXRSZGL+8Wsc/BTkR/bjzbjnv1ireLbuKOe+W826t7MVa6AQ7G+8WC28ZAJ7v
# DATA 7USRiOJp39Zzq1+7zPeFIw2e7QGbcWoJ3RQbRtQ+ZH0t5W1SyzOMZhpg/z1PVNVC6Xq7v6HcXrphyqQUpSihmudNV5ZcMa6fMu+u
# DATA HaHnRi/WD9lAKvO26r7PW171Rt5gyFuvC6XFDjJeQUItj1S5Do1qWdpPpm40MdMPzrimSorQC7unc8kree3+Yj9WqVBjBwIFFgYj
# DATA urtQS90/48tSFpZxFMqmGwrimpYvzPSylpmE8qMo8OEinSrZfWWbLsklaeKhmGdDGg/HsiH9ogTxlAaQGCkYjKz2ZqtZ3h2J+1WI
# DATA segHZlSie6zXONBe2pzMGNiGY6+Iv+OHsusKW+IFI0Wzh4JnIHdJPS14XGg5HvwsIAuLVyZBQq8y1tYxXgdrahgOBGOFMMkiNhKE
# DATA WFBkBTUcGoOkY+tAmqcI8/lQoLRXEePJDvi1vFMgWcNU09aBlqBkvcpEdnLCFuqBZ7YL6D1xQ7ZhNF4WWf2TNzyTocaZns70XMX0
# DATA dLbmT9fWXGgdPodq1Xyiw5wumDXDepYZ+hbMTo4VKOSjQJYJY22FJg+x7BJ3vs+fuvXzL/nKf8s5nSuvUg+abVj6WCDCNUe4mnLC
# DATA zzqzKBf8Hn/LinBnj+tJM21HmCzIuw4GbTG/jf7VlXdnTvvxDj4qxBlxc+sp/sJpWUFYPDm2ou2xDBx83z/g6Qv0nI1hdpWX7GRy
# DATA NDCLgvAn7lBIwwNZXpS5E2iEQ3+P5y4F7zYvZ421BaXuUfYZaiVcxuKMY4Mnu9blYz2crDRN61ipEmQr07WHwx5CjcOH2Louy5BS
# DATA vc8d7nHuxlOCKaMKtRf0dibUXdiwsn85/OLwd4wlA0HsCX/+Dugyxob9GUQx/HL4xSyl7H8zP34+/Xb6BCiyf+MLfz78YvodLuW8
# DATA 6dfTR4wi+x2+4wZ+3eEf6A9AZF/R6wAye0I/P2KU2bcUwA/47fAzCuZbwMoOP/MojEd04Q+4CDSaY5e9ENYh0sZTL/hDWK5c195L
# DATA IJL6owdY5fMHQQ5uD5qVjnjuOPRl+oNBhmaoOCrNa0jQy/AmAw6MtcknYY/ZqNSifd7NSRNLfyyQ1ABb9akzW0otE5h0IAOlg5bZ
# DATA tqLVYZw3uixTKmdHLuuEcg4zNne+oa5wRZ2hl2HcM3dSpZOaODpleBnP88OYNyCgOfDOMB1VRzBbrdROnWKmO5tuyM/5PXEqxe3d
# DATA oDORbSI9YcdD8oNBztyLeaz26pVq+X44gK3t96hyYx/JZe3pZXSGWGGjgAIWkEI4QBcsZqCyjKRN9gy+edWqudjESTe1Z4UvWxp5
# DATA Ry9zFsCpWQCaW3b8gf+lcBCd56B/2mP+SkP+MUf8Mx/wpT6mEm/Ty56L5nMW3LJUir1A5uixeKSYwu1F3fS+Pc6G8S7FcofXTdDo
# DATA QuzTNJYRI476/pATLq9FHyXnBqh2grqEpRaNTJL9mjziSr33jDhbvCK2jHNOVQqPsmOC18mADyCIuMv2tWFARRAjll4HB37w8geD
# DATA aF9OR3TU5lJgo4YBF/VuNBmB/cUMqrAV9pBVsO4YtELjEeOmYCyIBgLjucwZAgVyGkTz4VOOY+Y4Zo5jdoYcsxVHmpWmPCvYx+dn
# DATA 4p/Ewn9KA9+BzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHM
# DATA HMjsuQGZlZvVWqN8UpBZt+t3iy8QyCy14nxcjlmd8qRY3a3Xm3uVzerb9SyCrBzU293ZnCyWKCuru7Vmgz9XABlTn6uUsfy52fRK
# DATA lMOVarFfahbz9K/6XNKfM1AvyvlOtzwP6lVuzkShXKMoFMsflxpFr1QCgs0rl4rjEtzGzaPwYY2a32jPfVOtPoNDKzVq4JJ5lXJ+
# DATA s+qV6lVA0Eo1yrhShclv1c0jXteu1FvzaWUWRC2P6YAPgX6p0d7mHJAZxSUBmVGkDMhMcGxJC6hWuo3yyvlbn/OqcrGRvKpSKp3h
# DATA qypCZJNXleuNM3xVrWynqlk8w1fVGUWnU1U55Qw8FlSOuzQNlZPe0YLKVcv1SrOThsplEXJzoXJBKWh0aglUrtapB82Kgcq16+2g
# DATA bUHlKvTeZv3MoXKyuzAvywx6mKvwDMLTq1PGdmmK+Wc/k4XCvRVQZx76uVn6W3Ue/Q3+z8befq4u/k8Vct9fDfJWaCxza+rpWRJo
# DATA doHENu91+cx4NlXJpMJhcYsFrq9ftJrUgXXSTq/j2WEeu2uxVLUYDGdl1RJ7bibO6WnRGVqHjjHnGHOOMecYc44x5xhzjjHnGHOO
# DATA MecYc44x5xhzLxljDnUhHNMMf+RDi50q2GWDndu68omZkwzjLa4n0kvx+WVcvWe1fGn4W1dMsw+76z/jR1XD3fhEcem0chHEUOXM
# DATA FyOOhtxVi3F5+VN5dWcia89bdkC/EtwdLiUIPObSyZKOfW++tPGrUu1CqYbo6NCuSACtCc0XUagmZiw3ywq0gyDoxODd6WcAyRMZ
# DATA gthoL3WDfelAhnIqT8S+6BKfYEwlBxmNU4xb2qwf4cWSVbL4tM4Tuo2CLD6sr/u5vVxIheBfUIb23sav1kNqGsXX6sVLpY1cEZu+
# DATA uNVj/Wmrv3VlvX9lq1StFl/7cO0mVUk+YsmhIoOU4cP51O1FNGftX6wXN35Zrm7QDKzDelbr5dyHa0XczY/pZ/q/pBtnb7qc1BzJ
# DATA ctSA9ZhjraoOnEdbHL91pJ5Rg//js39GxsaXceXC1rzCXA9fTRfia6XapaLOTQ718qcbhY+icEDPMrhQIq0+Xpjzym44CONdJYpa
# DATA qunCxGlZcbgIAPG9AVQmBAeA5xl6uJ6pMHldKzbsakGNh+uRyZYNiuRlLnAqibyeVdDzry0zGbnlofEk4XyCcZCMIXXoWCtnaHEL
# DATA HbJmK+pKZ+ZdFLg+D10YP0Q/Y8VRwr6jw9QP0YCLsAymUR9Ec0oRTiliuVKEdUzR6UU4vYhj60Us1Ck9Ex2JW5Nx0gB415bW9JSR
# DATA 3YhKPI8yRuehYy/Gisi4j8SKySjX41KiW6/vN52XuWCE3oubl9SCuRKuX6BHrwZcVqQf42Q585CMsPe6GnmPUtI3wZgoJVcSJf1q
# DATA cZ6UfsWW0m+Ui7aWfqm2WErfMmgQfY44TUxoVsXVKi2nn7rZyjc7iBm1fI7ZlUpR2x+LdfWrHM9q7eg76xxmfU6YM9r7+gAjpZsP
# DATA Il5RRrEwg9By6Fb5ReVMwoTCpIHTlC437fjIZkKqnG4k4xkPhTIBuWJdzhTI6bz2NsZNbvH2W5OrZ/NSOfjo0UA7om4i9eb0Twne
# DATA MymXhXQE6ckUJuDFRSJch39PpG6UsaIteVs5w2jMdGhCZ9n9qU6ezSAIf6RuUQK8VIVZewaSM6ynwXADFnPQDIJFGjRp0RmbCjbL
# DATA /5rPCZMMTM0fMBLqFQr2bekhyIaAHck3ePHFLdIWhpuXuHnJEfOSlP3ppiZuanL0jOOZStxhjEcF15FA5vQSlbs3zUREgAes+WTa
# DATA GpWeH7PIFQSnWHPMiFDlRDmt74vj0gihabGG7OQig17ANhsb+y08WtsAE77m+yI8FwhhFq5StG9KDFXo2ExpmNFF2RN/PEE0d/i3
# DATA SXxAY+6AmV6UQOkscgpCJNMjPdAykJ67i/iBDnS4G42jnZE/5KF6GMCQVvK+4YilxySJ6WFv7DNW+UY0EmVdNdZl4aaCSLYsP0mt
# DATA mCMWDo07MvRt+wqDjG2CqmMT3z1Wp/aBIoc+3Lbw0wQrsevbeFF4yEEYYKk1+PaWxT7ssFW3NPJZ41FSYJACAhGODUEYKv5jA3pu
# DATA syCcwl9oTeJEWU9YtmntPVUsLXTZwiewem1f6u+SNG1jh/0gArk1mywxE9Lc2BlVRVORySy8Bfe+ejPylcy2XRB8FbJBsoB/ALAX
# DATA kcdacptl22DU5FCJBpIUMO/gvY0mscoPFXBI+bC9F4UdlqRmlTYAFCRLaYCKmBjbh9TakE+68e6U+VN6jvWvhSaiHOAyKdNxxoJ6
# DATA Srg66sosDDp0/X7UkcaNwuPLpqw8fXgu6nbhU9dlpzWspQxz3nDSIgvFeo7157gR+h1YQN6I67BUVhq7GF7Mr/RAYqdBhyztmNrk
# DATA siTeARpcwb3GGESsJIJQJi+kniGEthd1d5TWIT3fnfR6B4q3omLKbpyYK6qku58iFbKyoPQJ+7uRUkekDhI7QamIR7toh1Jg6OOz
# DATA iFoxTH969rSjhTlbemU1aGc6/6RN5+Oywp6xOrS95385LOwuRgINu2SjSur7clrY86Mm/UJIqh5FkEj2/WuW12lCxdIK2afNFMsq
# DATA js9Fiin3G6t5o1B5FxoZQVIjYjFrop7tDg2GuhO7cpO1S4QrRlMV1ieWSRO9j37HPW+GieWM3gOS2QPY5UIjo3qT3CszE9i0sjs9
# DATA goUXQorsQN10Meotap5iL8PORfXlqYU/z8G4FBMCV6whOc/oj8MCYxni4Qg1Og5MMxMFZ99MV2WbDRn2fdxFdm7K20o2N0SLbS10
# DATA trR5Cik5NWFRcm3gzqyzzdh6PzUrL8Ga7QctJX5tU83+8/Tx9F/zh7+f/siUsSfTH6Z/ZroYfTr8u8PPpo9swtjhF7gyCzj7r7g8
# DATA /YoefsyIsscefXlEF5/Q5R9AJpt+5fE9XzPj7B/kvsMvFcjsEUhq9IIv6N8vFciM4/MIcTr8ezDQmHf25+mP9APd/41jm70otqw0
# DATA cjQ8Lb7OS1aGvIl1IJrDibo4T94iCm6MVo84Uit/DyqLzJAX71G0x14ef5R4lSwSIprHUpTZ29loOJyZbdMmHcV508zmFMzZEc3E
# DATA pxLPvFxdz94uOwjM3beDmEagtgzYXEinjDYT95Lo+cO1Igt/TC1wYLOVCu/UuWbbnqV3nswMTA3gRWMI6Ux6TOFoHeBvnKZQ7jlQ
# DATA TySCYudcvfUe3S+a5jnNqdD7XQzEhO2fPcCLPbrYm+GZrVgzF9s4s83uWdHNVkyK45w5a+Ck1oDGmp3MCHgpnFrnaACcxfi/0vB/
# DATA vNH/HAd/qZ8zOWGhzp5JCzoLstlMIpluRlkVz0YLjDNZVvaoeqKmXhLQU857++7dW3dy6mCpWhnmkuE9oyOyH3hlh5OBERpOiYSm
# DATA NFJlqT0POk/1mLsq3sxUBY/yGspgaQMAKQvbwJwlRkAacDYcBR34RtJGgW0M5LiZorPwYGAM2so8YKsAHCoxDwU5xfGP6TUJ3Yyd
# DATA KvFBzEcp1T0txzdzfDPHNztTvtlqY81KE59jGcjna/GfxOA/NXvfYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxh
# DATA zxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz27PnBnm1WN+v1k2LPKt1Gt/UCYc9m1p9XQp9x5qrMY0qY0Laq5dRhsVK9
# DATA nM71irCcJNubqYzrNINa0M3gmyrNWk1QXVl8U1Wy2IqHvFviIeyrJB6V7KG1chKNahZbN48XVrd4YaXNpmFQpQhpv6h2mqVGZbbm
# DATA NKtUdZq7Uues5Pn11mbbn8tPW5a8spDSzih5ZYvmtXLy6KFTS15FGF9nlLyKevpYyaOHnip5lXL5uWgklUrz7BpJpV56ikZSaRaf
# DATA upHYyTv1RpJK3rEbCZL3tI3ETt6pN5JU8o7dSJC8p20ktVLzuWgktUr17BoJxeIpGkmtUX/qRmIn79QbSSp5x24kSN7TNhI7eafe
# DATA SFLJO3YjQfJO1khsYGux6VVrtb1qfbeyWd3LV+v9fGmz7lXre5WjAKqLG8FJaJhs6RoaJhvNFg2z0qqXm7WT0DCLgd8tWTTMSj1o
# DATA Vg0Ns9Vudzpti4ZZqsnPZ0vDVJt5ZXZnOXvUspvhY/KEnUx026m2yWvsc7ZNpELF/HX2nuxWhdklsyYvmRWa2Coji2apUNWC+dKQ
# DATA 67x6ln5MzwLnbzZM7qbZ5M7I76fW6I5KrnpmzvL87A16pX4mz2fvTryIi3ZIyotKUkTiCpgJBEsNs6hPVe3SywWbm5vwwBwP3ske
# DATA ozmpYrfhjO95drvQQu6no3U6WqejdTpap6N1Olqno3U6WqejdTpap6N1Olqno3WeAq1zFs25E7YUQBGrczA9FRxTM6joysVSsdqs
# DATA NeqXU3MW9RgfHsZjGnFIhvlkiCsXSniyXL2s2JjX1DF26AcMxru9A8O5YkQixYTq1ZvY379eZiziW+HrglS8jnPmckp52JvEHgSb
# DATA PfUiflZFadHz21659kvztkRoR+allAd7AaM61ykOv8Ia/8a8kGyWoXXO1AnCOEGYlCDM7KFjpw7j1GFOrg6zUEn5LFVjdGcNOQhp
# DATA LyguVnLARhveeWNJyDw/OmbnATSUoZJBHzKQsQoHXz0CJKifTHXzcQrZBjfCXJBgyeII8k1FfafBCS6mCZrhHCxB9Rlhs2DJEIOi
# DATA ToK3/uvw9aOAiFZwJin2NZOa2tFpKR8jGWJtoAeAV1RMgvUbR8dXP2ciay5YMV0t01eMqbaDuJ1CKBGSI4ndQl3XMAyOqi5JIAl4
# DATA Mrlkot44Kub1JbFeCPkzXYCeMvF4qAr5hYf+zSP9GQsxML0feiaqY8Ly4ObRMfI6sA24SP0+zwF4eYYFYdRcs02TKlaLZqgJ9kbS
# DATA 9Cbn7e9S5SPjcLQTWKGp3O12qa9tTUbwbeA5mlyNAig0hWMt8KP81TLziFmWm5WYqEodiIHMOph2PSt4V6M+u8Wo68spsZ5Bx+g/
# DATA JaJLajLXkSf8kdJFSmyZBDLbp3hNRuxbVeJDK1ADf2pKMY554iYCCyYCzuZ/KWz+45JOnhelSHunxHLkyVshj5iilsjr0RCJG7Bq
# DATA D7WtfrCUffLs5CVfLHW1o9SlM3s8zgJ8Miugedrwk3k6pHMBKKmy01tipCLPA/y9CXtemwhz72BVz6V3vC6mtTE0jin3rch/jKsM
# DATA WXAQIBHR+PTHUubK3FwFh3knmXZrvOLbd29cz3lX79zJqXFY2gsPC0rLHRBLmReJ0OIQKqG+VlJlpUYqBSP7GcbJvEGD7biBh2MM
# DATA 20uIinekM5ANb8thkdtWJFQl1inahhLoQMmjcuw4QZSwTgCaXzBoQxF0EFD8lB5rjmovVdddvcwm8qxpVdalaM50B3JE1LXgrFjT
# DATA OtoKpsgGtzpgGIg/Q2CkMPtF+54N6NGBksRUsSx4tzSnBjHn1THdkfle1w97k9EymuVtCQYLV4t4li+RBW73184Gdzb4XBtcVRLn
# DATA iXee+JR1t9B4f37027lOY6ROcM6+J55C44EXX00YY+NexINkWnxcu9Cz9LPJEDjBgvcb7BE/MIgWuqMzaUNEpo+x2EgbG387E43Z
# DATA 3llZyD3RLZDmia9XXtWG3x0c8+aGDf2KWAGwZcah+oJXLxorcSy993iEjyLMjVe1xVlP9sYoojGYGvbu3BvekzG9C2rzglveh8mG
# DATA VIoWN4tN49aLeOdF/X4ZjLLRUIaqMuCMxcNv6lx5Q21O5Bqc8zCsdKnvj6jMGPtJVW3c4TvVGJHzZDDOaaltcO6AKY53JdyOitaC
# DATA eNzwB1SnOrYtaCKznUjgZ36XKNimm7G/qERHAcS7efFAW15HR+Q34Wg8gaI6S4lbcVAFzGYe11aWlOc+ZRT1TGTeHbKiirmBKnkw
# DATA ZpX0IQ+elEG9nq7qsRWfi6qgLqpKt4BLvxz7fUfbeUnei8nnd/o06OtZTsL20UriitQe70aTXofbpZizA1h+2HiOqZWoq0sBFzy2
# DATA L8kC7kUHfQ6C7HPwrH2Iw1sy9GDRfxS1eOBUEvOTAbMQVUjLgOCDaF/plWvT2R/v6ui/P2I5e6r3HoubiLOb11u035idzmSNUzC+
# DATA 9jajl6LOju/BD8xITWxcIKEAWdS388QIpPoBHOw0nAcDfW9HsR6TtcFlibkhrmiVHl/E8+FXN+595VlHxPR6RsJV2A16Q9WfyYKn
# DATA 1RexDD4NlFEKqjAM/AcoYekxUfewZtkJ+niBPcNSYAUKReaDjIVHK7CnZsqOscHnZv0T9TPsr8gQ/2nZ9p9+eu/TDwdrr/zVT/0/
# DATA yvqgdx8dRjiYAKo6PDj1d2Dtsl6t/pVaN878WyrWauW/Kib//VWxVGoU63/lFc8jAyZoc/T6v3o5//v5z39+eyKEiDZ1IGGHxxlU
# DATA irWY9yLnGfuRVBDv6vV3qNfgZU5q31Gvw0v49ECBwnpFpFLItt3hwzb6+0dkH+rPUfwKj17o9Hthy1OXb9FXfcvIPBhPWso/o6/g
# DATA SBaGA/19QqbLK6+8f3v71q1rt7GBem1t7RU+Y/OK2mDZlX3V7Gxap8lkJ7jUjdc2eDcjToasgcF3kXrFi6D6Xmz3QprBrF1+RbZa
# DATA d+MC8gFuvjsHg/Y6Hsp5azRfb65ZO1DX2CmUR+j5JLfWNja0f6kQPAzH66WNy69k932mo8bnyO6rh+gN1DvuD/jNSUBBG7mV8z5Q
# DATA kZn/7nu5VzzP+2Qsp0gulXi7Q67vP3x90sXex1K90qzmHpCVeSfcGfi9S2t33nnr1+9cv76Wi8edMLr0wRpdp+FhLbc2DIf4R32/
# DATA 9+mGyh61MTUYjWjo+e1v9UbVmAO0L/BiuWx8XZwlsod4K3VaSz/fwVgwjtSxCpX/Ohr84GtcUAf8EhyMwut/JoeHCmF8x+8G75Bd
# DATA tINDCri9gPy6ipXsDdyZuea96hXnXb7Cp23mpkFfUXHdhyGzruKbfSPdn5zaygblffoKKvErr9AUGm7K+0w3Wg8H8ZBG4ftS6Dz5
# DATA 37iEIkYW8Ao6LsEG4A8FtiZiTKHW1/JrG/ihFwzW5UFKSK1UxjU8OQoK2E/A24jXR2sfbOf/g5//22J+837h4qX/KX/vwlr6hfhv
# DATA 5GMq9xsk7BqKf33tncEeTvtYPQk/s7bBz6iBeItbeioxGzoRcgtXlnWq+eP7OKlLMa16v/KwoVf9szwOHK4XPGyTrRvLRFLFAPbm
# DATA qIPeAP1RgXc/rKt3ourcx/7q9Y2NVJ7GFNOxP2ijKvLjOQ+nB0x2qqsbVO280kq5o6a6CmMajFTs9PUtHc8PivfkB30j9nzLTXwo
# DATA ce2dDhXLmno8GOyFo2jQV3vD7ftoOtcNd+jeTz7dkCvXBntyJMhOarYS+Pku1YB7n9Srn9LNJhYbutJYWWO9PJM91i8bqvE8TSbh
# DATA NLQccOGvmKxLpxEO7BxIXjFbjHx/DkdvOZJrZOfhaQmGL4yyFx4Wi5lLW2tqz4pcS943P1nvDeLJEMMVzS6saKpE4T8+7XmfUiY9
# DATA Be8YXKfX5LzSRjYx81vr/XtWs733K3oSp1aPipnOcLv60HNWzDjLCzQ8BoOOOoBq2uukv45Cxi0FmmxQ98bn/FD2WIeg7OGnUfLl
# DATA Wn2F5nvNisa8JvwLrC3BseH1Fcfrjaj9AKdr8A9VPnpwdMDTp5zMl9tcH3GSAQWHTllgemT6F1SQ2IFFfa+i5cGWwZyW6X1qkeiy
# DATA 0M/gktIzf/igWTIU08V418f+K2mupvfbosgOAr4ojixluhTuBrBd/NHBGywsGI0OWNgufLi1Ri8e+O0JDpSbkRydN01VO/rmJAOp
# DATA 1O4rK4Z7VXPLhnfRW7NrmnlE+8wjdCdRXAAhbF2Hk8OVd++/f/vdm9f/xvutfLt6+9r2Xf3l2r+/ej3nFSMgPUyYnDr6udvh0JJX
# DATA UPe0L5Gn5hb4/XRtlGtqoEQ7LHxEBbeuqswFbprJS8Z2wjmjFU9ty7ISC1Rg6x+kbsN/ax2uJegu5Sl8yot7Fx9NrheSXN/CYS9Y
# DATA lwX8VaUBaTd4mJsNOp9XVYJD1/3VJTxtvvHbjDktL6dpdr4zioZb27C45oUb6yUask+3BhG9Zz+PmW8IkEwsoVDJ5VFya9yjmYLc
# DATA mBsgYklVBE9qm1eHolsNvsNM0QM+fsYXZWCng72Xg7NgPBkF92UL5dbd0UQdvNYfxfrcqhRzsm7K1zfSBWm1GFWo2oiCn2q4nr59
# DATA teFKh5npARe20NW6SbbEvJB9YmO7lxT7Qln02fpoVT82yiTT/fHYb+/acb03W2rz/ls1z0tLM12dzEsb2Kvn94edT0q5mlgGbEPD
# DATA 7hyM19U3ZSdfOkbeWpNMidRM9rIcQPIS82sXWz56me6Bom0ydjYaS4po1JfyoWGsHaSLx5Ns2rKefuPab26+d/36kSVHT9Isad6T
# DATA SXnVdHG9CQGHDTUDwEi0rqoxT4rQc+sZdmF7tMNe/Vv8iyo6uQ1n+e776neaA+SV0U1p0nsvrIqx6Bk24ec+QbfBFlMP8j94NFaR
# DATA SHXYfG5jPZnM4L6Cik/Ok288wVDW7ENgOL1r/A+EWE1Av1Aj/sU3Xvd42hkzGlR1tbbDuuC9i0Hb9xjd42H30gBeyrZH45M/JKMm
# DATA Y4jcYef+NczC1m5G2Med1Mi28aG3+Ho3HPWDzhrKiCra/fswB+6T/bblrd2/jxK7f39NIi3F95y6Ekc4xd4PzsLtt5r/r1yu18pZ
# DATA /1+xWKo4/995/PeLn12cxKOLrXBwkUwHb3gw3o0GlVd+/vOfs3CH8Gqx+CILY1hjwIovliuiYaCht3oD121tRnk82+r1qFtY4hXE
# DATA MkW9qr9hT5P+vOvH8A3qryH0wUaWE/Dk/kRZQTRfdyfjsGe+8RzCfIt7S7yQ/sh2QmadkuPdkRDwzAVqZCmPJUd5MupRjKXn1PGm
# DATA azz5o46FF088mb1PJK9lyExGTzUsUCZv2x0cTGqa83itAy4XUxpsqWMZZRR8FKj1P2SIzDpjLiwZdLAXbJ1mOHHi9JFOck509G3q
# DATA UVbgQWno52TctnwuPFfhOyy/C88fsbdzjfdCrW3o8GR+MGSPp5q8Y6/OlkxC5B1jnGkZ62kQB60nqfJTIYzvxwd9bHVZt0xCTuba
# DATA 9P+cPvamX08fTf9t+uTw88M/Tr+iz4+n33uHf0cfvpl+5x3+/fTx4Wd07Wvv8PPpk+n3dMuP0+/odvzw+fTbwy8O/5F+4qe/w9dL
# DATA HqYAMMolBmpkU9GRI4uFPuzxdfkSK/ONp6L3I9to41XPLe3q6C5yZwRkNUg+dyb9Yax/CwZYorzvx+0wFNMCu8UwTG6V9TxL3Cmd
# DATA HM9rWZhJzVX7D9Dyh2aCWkhmqGQVUOy3UimaM/RjYtjepSJbR/gouoUzR9xAM0ZEOV0ZsOK+j4nhFk8KV5pRItM25v3c7U2gGZP6
# DATA CXHAhuJ1fQ+lfRBpZ6C6YxQwMkzLS0mx2t4Zuofz72dkBtBcKh05Mzm/3+1Yc+9U9qkJ+O037An4G+/cvnb17ru3/yYd5ZkJcSod
# DATA 9tvSz821ltWzDHSf8+zMM5JYNLQC19eYMyUz2aI7JgNucvyjas+yCqxcScaBDT+S0k6Ds6iywDW9/tqlxM11L/Utf++TYq5e+tT6
# DATA feO1DwsbF9SFe5+Uc/UKZiz2q61e4L9Nv6XW/t+pTf8O/cFfqIF/Ty3+B2/6r9zwp/9GPcCP9OOPdCMa/6McXaMrn9G1R970Ce74
# DATA gj4/MQ5n7vnEpdeDcMm6zgQaUszexfvo83VjhXPLyko1+cp4GVXAH6xhb2d86eJFdDUqX00AaNk0xQ8v0rvW7s3P52KtOJMN/+v0
# DATA L+jpqFN7hL6O+j9JHqWU8oR7SEr/E/yG/u8PnBnfI7/o6/SH6Q/UAz42Xmlg6+OsXzO3lvI8l7xXt5S3mG/fwPfyUeWD2DxB6TzB
# DATA i/H+rxDNR6tGP+nRpes//PLwd+jFTeGp2bzla2Y/ifiaOaK2J27Majr878w0mtIpP6hKkFqbMWWYaT2pID9oXrpnB6dz60Cm2rZX
# DATA dV5Rnrggv7Em4VqVJ9skP/iPF+9d2FinxngxaXuF+/9znq7+auPia2vKLTvjyJYAseFuAPmlHXb7Uu5+slbAFLxQWPtU9uomP/Ej
# DATA H5Tv6ZpEubZxRNKz6b2UatpSefiMRj6pOx4/h8Z8+E/T73NJD6BbO7f8R3TzIwREt1HPMP0KfYDqHyhwndffHf6JatiPqJ6oufT9
# DATA SytXRXJwXkuWtJbuoSXrdNtZiCfDgaqoyzPhiLbAGfIdNS0qco8T9bWybSjGh38io8aOsXIZqSUBaBDavZ38Oq+bk2Qdr6c7VtM3
# DATA xbo8uSop6HXFWXdET8x34xuvPNEtaIxcMVUJ4CnTwaIuU7XEdV6ooNv4362t2R66q39UN8ezg9J/lWQcfjGn1H44/ILyhKsxhqW/
# DATA cN36k7Tb+eMXj06XU79RNaYMeywZiaBnquzhnzy5AxdNTVDFzdGeV9o0n1wfRw+CQbp8Fy81U3fxYWH5d+oV7CCzFrzE/Av07JSy
# DATA 7Vvv5JPGuEKFUClaX9u+dev+rXdv392qFEvFDwe3r924uf3+9m+u3b+1ffPa9fvv3b6+pYAzbAzv+3vBpQoUGgZrqVa4ljxJkbl/
# DATA 991fX7vJywqcCLG837l599rtm9vX7//1+3fv37l29fa1u3yLmqkW+Nb7u8HD9QqM9XT4Hw7u3n7vzt37t26/++//Zqv04eDG9u3/
# DATA 8Pr2zfvXr721ffVv7l9/5+av71+7uf369WtvbLEqLC+pSGlhupm1wuaVEHvVla8X0xklQqsNNB684dxTVgV9q9dqldpMEf2L9J1J
# DATA ZyNV8/CPUsOoBlNY+FGeTxdK8gIde9m6y463VVKhLMIPTGWCsVheYg1SjcKASFGGkfAtVZwfKN6P0ed8f/ilMgbVL4+0V2SO4afi
# DATA ay3GrSdr6ZfSpsYnn84ua5ubly3mc2l8cC9ln2ORev4CNS82t42Q3LIl5yR6H9BT91h2jp9b2OXrDaj31bLYurUKNgyCUUxznL1g
# DATA NAppCr+2ljgwRO+R/RV6jTXCHuCwLUcAWGnC7G7VfajXCrDVV1wXbKTAcbuVzTVsT53NuZvynhtY7zIGqQSAEZmeWUvPeFS82Q9m
# DATA vvxs9t6Zketr7mRpXKKaQ33OY6ny/zT9Z+5ZcQl9Lbriv8DzQE2BDBAEmtd3H/5jqqtODcdcCBIHvqryL57NB5XiO8EYi93xnMyI
# DATA pS6pmqgakw5wdlz22Gj8ge2abxA5WA+ZQeUHlSD8Q9/Vij3MTLQjavBkX9AAh4coOIxWyLDHSZHMz3e1AWNx3FbJeTUUfEtx+UcZ
# DATA N1QkZpIlI3C2AJQpriOxgZpTmpmoDeDgCqGPa26kfmxmEm8q9ZZxA67P7zc+WHtj++7269t3rmE0Wru3UdDP2ssn678ODthFl/Nm
# DATA XIaZ95l1UFXi+qe5Ay2VFarpd1xy6Lq5M3wsBghsNFxMbGkpULIsqev82ktFPLGtVDz0RzNdNhMPnkVaHST6EpQ/9ympZoorZocU
# DATA l0imFfBlFYRcwZGZwG4Nt2XjB90XxpwhcMZl9h/I6lCyfKyXhbEmFix+101KntV8kRZxKJE1zWvwSNW6df/qbXajEIrm5sxSKGfv
# DATA whazMEm8zNcLWaiHcp8/6qKRo1K4whHWsZeYbctDemDayHgt+THxWn4672VYhoQrbj2bbbz7am2j0JMpNuZ/Oj7pQUutGEi8ZWuE
# DATA FT8W9NdBWcmh65yYtXdubUsAmIi+1Ytafu+dW3t1fTETa0qcqcP0uM4xZd2byzpKsxmvajhExdXRW+VkBD5gY4OzQ1cv24/MExjc
# DATA UpgMyOhe/5UOSBz62I2FIU21H/YP8+1236VCYkfCYmdQ0ornD1bcSX4ujjGaJ3zLPvInc4cH/kFGgcvajvqKu9g/8fTO7iE88U88
# DATA trxq1oCQavY6R+YNEioHTj5CI4KUFf8E+3XR6LCgd7PGAR0tu6dV0T5xR5uOLN0nN5hse4y5oDVwFbzpP8vI+xVH/Q/8wzcqrV+r
# DATA Uv2GS4LnL1cxwzDpunnt7vvv3v51xl6al8UarBGp9KrvMW+DXFe3b2CXqxiObTGh79sjXsawV0ZxzMPVzJsSm2V2fQRnpzZmnhAD
# DATA feFDvJP10isz+3s++TTVexuv4BxTe3b/Kd8tXd9sP6DK/j97PA+X6eljs+Rqb9JMuWzMLIotqc94zvvE+/W1v9n6zfb1965pPwld
# DATA yOyp4ZmAIVXbkwLxV+K0O5NwMTGYuy2IQliSjLkx/4HX1P7CxtaP4pX4nCfq1uRK+WbFm4OJ1zdrK0xKeFOqTo10d6kNXun5ShLT
# DATA pRmcmabSx/9FTfvYWypZa5UXX80kgJ7+vZl4673vFDN7nVSffkjWT19ZuoM5tc9aTb7Tm9CtmSyMXGTj19zF/b32Ec30Y9IfI00/
# DATA StIpUV/OmdUmzRYrZffjXb9cq9up6YQ7OHe4pdfyC+qWjWQ/rLUMzCtha6PW/KU9NLL27mTwAI2Mzeie3291/Et6RY+pCdYJgY2c
# DATA 11rL+tMlRgU5TbzO4aXSpX7fDR7KJ7NWI2dG7yMhNKQme2zV5D2KxrP7b9WqWU+wItLlDcVuZZ8tth8jJVj+5TF6iBVqPEBfMYIN
# DATA k5XEO29vU87dee/GnaTXhZdxmFrUXuEsh3jQJOSNJDIczZUcIFxpkjVxXj3hiv6VtFGpUNQQzGAtS7FI7kU7HTi3ILt9U9Vn48Ka
# DATA 561dkBhe4K35mVjqMtlj3YD7UjRJvudkFBlgbXtNzrEdXUy8lVsbUmZ+MYr22RScibu9aWFD3Ca8Zdm2uhculVA5+Pku71Ld8Lz1
# DATA TOlsYKNdtL94oUQvA7AZj2jPtWgWlpzupH60bBgeLpTb+PD3GEG+oF7re6u7ZXziFufgxXnrELwKPK8q6h9UtaarM50FKrhe55ib
# DATA lv+SjaWy0CSWcPQvq4WL3CtW6jgb2cDWadO9gpKnovE+2dddkBPTBeyyUPt5x0H2ot6UHZsryrZJ3WisFVNl2e0ktda2OiQeHMU1
# DATA 7QDjHR56kbWXCoQ3H8CllW3R7w0eDHCu3gi0qifWMseAVLpf3cpWMat6satdF0a6BHBJl4CM5VmnCWeaHumkfc3m48b87OGUqdP0
# DATA eITnhlZSFif/JguT4CcVAcmHtXRx6/FhTWPc86A8jNZD6TBD7r2hq8AnXzigD3Txshbc2r2NjflBWsnN1JCNZL4290keCrSjADH4
# DATA wD7cobIN9awbUsxGvNlWBX1Pzmnirdzt6+0ayTE3FSWVBhWtVEmYZxbVyiXPWl3iIOyKSWBlxCpPZnMDPo4PFO9jTRbiGCDDkxB5
# DATA yQeCB5HUy/2chqCzdi/Vu+oHpB6hcrAr6HYkpL+sDZFONp+45SqQH6kHMnV3tQb1f6sBVXXJf0c915/JKKap8uF/SnoxcVVSZ85z
# DATA ZbLOaDoK03SmH+c+0PSQYjqnp1jD1CiYXgJRvT0PlOnjXnaX7rfiqAfymZVB6kkT7kVceGWlQYIs8qi3x0yf+P4o6PnjcC+4P47s
# DATA E00wBFL38pLq7KGolEmfN9bKEnv+j8ogTvb7iRH/FVZYOWfZkYHVe56MT/+McUdmLY84v7+ylhF1YnWj4c5qdjg8OsI8dH1JYdNs
# DATA nef4n6M7XRzhtJmezqtXVA0YBJPxyIfkg9QE7ZEgu9aovkDvB/mfrM1A929ngMO4Qjzq+QfBKPbAXPX87hiK49GAUa+8LfSyklWR
# DATA 4+Kii2JeZFZq5m2wSfo3PWLq5woHfr9nD6XJD3JdDnDkFz638Hf6+d5sJU40cC56xq+ebQgLi3jOVtO5/lX1tnS7tAoimQZaNYt9
# DATA iVxCR4Q+s0NQlT4f2vj/2Xv35rau8164f/NTbF/SDdAAeJEsK1Bgl5Jom40k8pBUnJRCMSABiohBAMEGJLE0zvjy9rRnkkmmnc47
# DATA ZzrT9uQbKK7duIntfAXpK7yf5F3PZa31rMveAGnZbc9Jeo5F7L32uq9nPdffozrqBVor+nTdjbTGcVl5FA7ceapxjtJ6cj6zmhBt
# DATA c9jeKzI5uL1AZ1R/Zvl1Lmf7FDnaL/B0AldrHNK1zg+5DTgmf82OIl+CmuFTY+RhA8WnOfSWLG0kvn+GOjdSWyIt/txRRLieMHax
# DATA YnZRhhfSJy+QI5kri4so4vKkckU355IjOfD9FrvCsZPJKwnjzxKCEkMC9QZVdHY108soXEqef0RwR8N+x+Ar4XZa8u/UeT7XUSEF
# DATA mHpUO/w/oFB+/rHuQDWQLSlOXvMTulX2mLbnl2cUC+nJi7CbB6mZc7CnWcrJo6LWnFLAawJvaBtzvSIsPoDhR9A/4sqVxWfDuXby
# DATA 50KrGgQt1TyR1wPbtHGazyU/xDnBY8k2WSWho1wLOa36AnGEehsbdhv9TRBwwmHz8pWlcxw1cqfMeClrzGhzttyW/UHo8lFuRr6M
# DATA i726BEoq1BK98efrIkJwOMgFJF93LU3PUbuBmZLU3YCI292SjskQIZd9iwrAJiSjPtZrB6p/EIektekcb7BjZuYqSQtgD7R6Z4aT
# DATA AsVydFL/oEb8GzR9kNHoqXZTTUL26dNQG6VTd7qb1xzuBYQAjM8kK63eLhBqnysJyNNhv41uHfd1fPPYMjhT+miHXY4qU3bs8IUY
# DATA rDtMYY06tAc/6RIkNgFeT0+lTkjOJJJW0TXXGK8LziOdi/eYfX4AirCtZu5EsZq2HtnJce+0jT7U+QyW6B4X9yREXQlbEov37yVm
# DATA HVAI24NkysoZfd0i0XW9BDRBl32mLDv+crvhUHQY6ZkcXH6AFGw7N1CJ/7Gy10sOjxzXPT8QwULihJhQ/Svof+c2RLpp277Wgt/b
# DATA vr3Z2tvf2N808TBbm3t4YpmIIpAP3LDcGTsuVLLnEdc5y0MZltykvanVEgeUT5tDcT849mljo/LNlyIsjMNlTnsZwEq7QWCk6svi
# DATA Bkb+3ggkHt3gWCWYSM8ew73S8C0m+E7aQcKpI7V+dPANnIE/TVaHb7zxhpWIzSzLUO7dLuE9MMZv91FvOM2Srbsb72xWkmlGKQzA
# DATA H/BxVyR2HkxY96cOywhwK0WNhEmX/Gw6nLSTn6otARc7LuRjjOAed9XUTrsYJ95DfCHIs9VhKRbDMqYjGxjOsYdEAireyUN3wqZ7
# DATA RrV85paU2kF3MlGSXlwC1BcpfqUWk3uWt0BYrhLIbMaHtt8etAgCEvTKLebmSzS0Cs0yROcfnfQwYbtw5WR0ECYInQZsaa044B9C
# DATA RdmiKvGFVCuQ9GCzQmgPKhOnqo4h7AJBah73AFEN1/Rxe9yx+gSw/earhEmtjsEmPJyicgHj8ffogiEVPr8n6yhFij3VRt4EubTP
# DATA lfD5CXnGeFoi9BOx6vFf5vgUehZfnmyNWeWAvcUw3RQdprTMQISzDwDA6oMHr0ZA3KT3vONcQqpF6NcXz35LVmxQQimOGg1Jn0Sm
# DATA ggUWELwxgiQ2tEdwLIYDzMxuloof5o6e37vjj3mpv1Z6q/6gRn+Wz9cqFOxHXy8yaO3+Sc5IH6H5Ij5UMjOF49N7q2UH6m63YKzB
# DATA F+xv6F4R4aT4311ydvxqyosaFMnMI2fKdfqNcN+MMoJOa2TAZ4+ZRNFcxe2WwKNByfGjEsJ3OW7pNXUlQRzUwWozWU6ulg/qVz02
# DATA DSoOZgXOBL0pHN+v2SsCxOynuIV5uTneyIwM9EafkTaJBw6+H0UWyBuktwdK8W+GYqgt9dd0mBwv5M9Ysf8FxZ+TxlfvLIvanLnH
# DATA R77hwuoKbHkfuNsw8o3Oh+MX5ecb8otK0IK1Jvn7VBQSPiuYJUD2kCmZUyejCKl3rmvn4MxvhZ0lC06ADQp2be4AlGf9IYyrptMN
# DATA r300/KmpcQoZydX/1D+4/szZSbnAIGVfg6Xwq/JxLGlBxWIs3hZ/a9yOYBr0MzMDolA4JOGHHOzSWEsX8EtxvBsoVvt/oA7xI4rN
# DATA 9OhTYMD53MQT+pSLsiBAfzGVhnP84MkesVcAKuweHucl2b6ZEyOnNcUTUUHDoKF3t9Wk9gZ6tvzTIt+ZStVz08ucWQ7m85/V/NAU
# DATA GO/X32Ng4W+CSI6vkSR9gv/9+NmnzONcdC5HI/SqOKC0JOyb3mjYnqPjXmDz5h3hRLLD/qMK7fbj32Zjix2Xu9v4m2Bu/rca0m8w
# DATA uPLp818+/59MvPX86JCGqNbtDxTXoipgrgFcpz/GHfuJqunzkI36nYl5YVSWRk7UGLvY7+xwwKCAgWVG4cq61j9TVah2vrr6/Wt6
# DATA Vo5OaN9gO+RfR3a3B4iB9gC9VhD4tBnOyt87I87ZFFFt9hd486EzIj4QY8jT27OLRYFy3ui+c4Uo9o504uqirhvNKCwBKSNRc78u
# DATA KR+7pM3RWf6TiNL1WWw9L1/xPvsw0GMGpEurMo1uS2P489jpuTN87FglkI6y7iY4+e4g7mO5bKz/yJ8BKwZO0zVAKnq/e5aVDpa5
# DATA Hm6iKT+pdZ9MQBW8mH1Z+/JJ9btnvTCCNNReD9zNFjauL3BxhKrjeKCd6anWe5+TaQTdUMn6Bx5hpMyvR3zdgs4bD2VN8iEpO06E
# DATA Y39Oa4oOpHZudFIlCrvxhWzYofRXOXa3GFcj17/WngsqTZ9qPFFCi3ZnVfsrE5+OxUlpWeCBTyO2bvcLwTRfxPKDC2pgcXNtvIjV
# DATA El3kAhcY01lcJWn1lQ4u1jOGBuuspNXmSE+t+M53Tx81Wv52T4I9AYqHgqAW6wOeN1+Ox9m3dS4U/WBXTECJq3W63RH8wYoq4Slo
# DATA GSq42dOKpvIcLQ7a4ZcawcM8V5wc/4BfaSf5r9CsBpc7IlMkECul5uxfwRkHw0VtiPjzT/TVLjESBDMYcYKJc2368Df0rBzYA97E
# DATA sVvQivjR4uJBUIwbgCJZlS+NWSLvtnfY7by90j0+7qKCUHW+pDWH88jVIiMyFReNKV/fAz/+XY8H+Tzjw5q7+la2eJo3XISXhrU1
# DATA 3aMB0nMnzjoMQaJCQQySUy+MtRSJ3ncJOhf3EAGc6aQi1Lve0FptarwWYNTsUihtKjdwFZIGpvFg00YDRZRc4n0BsQNVJF9SRAps
# DATA NhvtxJFqHHITA/UQgL/hudMEy91fUV+qcVft/x4woLB5vRXlPBc6opQX489wMQ5Wm7WxQSvCJ9U1g19U12Xkcoi2EA1J/Zo8HBPk
# DATA t/77Zwxc3unhY7WmANsP6N2KR3mCjnLtTgefKIase9x7P41aJ5/9S+7JhcP+t2r3A2P6NxirpdbndxQFqjVUCZ2gL+Cg4BHBADQo
# DATA h2BaH6IH5S+lzPSJWBhehwOeQIjkwr/8ArXRcFRKD6e9PqS8QCOCsPnsn/QyJiGAEwImhCHC1YGLE8L4GxcPeD0eDftk4oYbU/MK
# DATA or4xZC7tDmB/EIQw26AgA8BA9QhwM/sQvKMqHGCKAhM/BsDC6kKshSOUYPwwzvPl5VjAo8992VQRcIcKcanOwpsBJUxBv5+++qqO
# DATA TTZbVN4yMaor7w+j7YBOCbOU7GJYMUryzVifOWmHKkswV7IedjKlz9y4WVSM000h1OHEFujexb5bcgPqBZ8cdjoMldeUK/fqjRKG
# DATA /IkqWMvwjnAK/ye7Icza5c65MTmOkTrqklv39vY37t3abO3/ZGcTlhWomTohSMgIUXdIsPhHJ93OtN8dpzNfa0j/Kx0Oh/05W4+p
# DATA MHHCznxq+txoJHlVGBpUzumAmHk1H6wbhZbUL3EI6RRSW3rjl53LlucJ9Agv8No1TI6NrX1KBrzfIk7d54ot/YLDgx3vqeLLl1Bs
# DATA 8Vi8lqQ3QttIqHV1gkfJTGacaT/NN6Ma/3VjDXZdtEJ6UBc5apCnjFAXbw/3zZXtbGKrPxP8JXzhaMvgwcKqsvmM59cxxvPzOCYN
# DATA mpl/xzH6c5jrAtI9j/zPIeQkih312ySLOS0WkgY1o+Y7SdAxoyu/iJ2hlxAIJ862FM/Rp47EosEMRRRFaJu3pt1/hbWJAFfc0Bv8
# DATA S5aK0Tj4leZ6wPJHwHwX3PHerj93p7GeIL2JXf4zN5DCFY5RypVYpiZ+CghdQztwhOa9BmnDK4nUjTYOUJgn1V+5aV5aFWJDFhA5
# DATA oiJ8t/BBRng7gEQPDI/yy30odl+VYt4gt+AOEXpCOrH6zpy6/COf88WO4e49udP2fq75HaN+r8+q5u+rs+pV8+OKenH9++3DpvNE
# DATA /71GfnKmsTiZIVSPQpjPMDDiaXKx++FzJP9PyTHibwAPRbsCWPj0XwQREgc5CwCMsB2WDJ04N54S9WQNoneM+r/u+40iL0Gem6xx
# DATA 4j3o5mQxAZ3gBGX+Vh+TZg0VU1aVRbmcwMGrrvUsOtpXPaFRQbf41EIp/rPi3tV71vMqehRm2hdrrhYfNeEaStdAouDPIKgj1xIi
# DATA gHhR0Iz54ku3TUJ/vD7bpz+uzf6CHfQf6Nhm7BYIuR4AuEmbE+qzI+GsOizLD5j2o77iwV45T+Fbin8NmrcxrQGssu24B4nkXukO
# DATA 2NHXcKMYfQY6gsUMOXV1HyjZ+Td4PejrA88V618tJnW1KgN8Qiih3BW23QdfGZkFKYsopN2JDwIIM4vz8YgTgsQcBsGR0G5J+OV5
# DATA OyEwCUZwmneZD7m2oCdebqTMH8B5B6xsuVduXIsdmhyhk/PCgUqiJA2lmfdJ4CvtGhvMjBwFAJWsxPZacZXZuS8jAKyLTNDXFECD
# DATA Tl3MLP1OarYLzNbSSf1gmTpmqa7iGZbtYJnqol0pDL8UfutB9JHJk5pvSLDxEyEGEJwIrmJOAI6LDaT9GTzLCHk6sIskm/nJ9g+T
# DATA qu/gf+W8AZ/SPVywAOwv9ikUt0TCCUJEiHoT0H3am+QdSTZ/tFyQoeJTfNkjsUisBdbhRVlog3MkcC3YQPWF42bjW4cs1UG0Zhjk
# DATA QZ0Sln58YC399HNx0jTPvP+poV4ENZe7OxxUHeuWjhPlOqTPt6Hn+o/LhDuh67gtYTeXR6JMtLmOeaXN5vA/yPbxLpWY3ugWTpGn
# DATA Q617PW0PFAfeSUDtITK8sdM+NQKui5B2HP7VbuTSNTzGuS/oMXghZHK9a/iXYiAgzfpFnNgEo02PLoJh/h2eXNa4a8AyZrpdW6y9
# DATA oPTuzLG1CiJKruefopctYaiRp3EBySyeNTpVRj6BCkJnPMGYxLj3IFu2dLnz3cy8K9lxtm06jK+u5QLe6QCUjA72jAsBQpyvwZu/
# DATA T2KdiNmYadkcHRF81vyWDBwRwHxFd/AszWKUTzsAaEz4LlTfbUEgV4vIkw7kKnGwCxCrC4Xeu0hj9I8DMzaw8OHQhjkQuj0XP4UP
# DATA gx+1Rzw39YYC8LkaG2OaB5EUHnkqM4+D1aUs39204EmaV188aDOIpjMhdDgrkZhNH4DKRwiyQ5+HEiRAB77NDgdBpguQzgCRSElU
# DATA Lmfi0tFg0JHhFh5PvazS9biZx1yFG3Gx0NH/W8NG8/cMhY2ycruN+6HfBUvx8PEA8iwO2qPsZDgJjd8S8zl9NOxPT/V1Y92pJmcj
# DATA UDGlh71BB81l1Om6TC8Ihn5ap3riDo2ZtkuFrhO9tZ8CR3gpXVzietrWXfJjHHCxHO7JurdFpUaO/pi5ZCMaBu+JiX6QOg1vEUJj
# DATA T3JZUGmDJvpNNeV+R2K4gvSrLK4sjUlKvzyhUAPNSDbd6IL8m9DEyUFIZ7+LekxznfITTku9wJ0Zu8JWXvgFBifNfmtOLBxkWaXu
# DATA oi2pJIATB5XoYiAsuchfbe3cFt/bUd9ytlOSc/m34DueemL2hXzkqXNBxEVUGjZRXf1+yVPCBLLoXPAzUKIEnobPfwn+Rjrll0UC
# DATA oTciVs5ey7zZ8nzePfG/fiHkCCnwIATnt6lNx1h5cKYn6CXtz0TQ40TUp5m6Zw7Pkm573O9hbgzO+ptV8O9uuyOqG2JM/kixne0J
# DATA x9n3xpinWH11ChE6imR2ho9dVJBa6AzvavdX/iN1+ytzNPumz/8pFfsL7DkzAFbt20XwNPsrMb2+Cx4hA0hY0e+ehpp243TrqkfA
# DATA UVwn9JgyrR442FtFnDxIbDkaDpTA3Pdx+GJbw9Hr6g/d/tj68ntEyx/WnxABRqwlcM/wAt9ItSAQ6bT3gCHK4DXAbpM2faFwff3a
# DATA QdT+FT272K4w47t0PA4T9Ig44jIMEfheoWEucMPXF6Jrugiewh0SxnvJovKxLWwriNX6Xbr38/UOl6AmgPlhnq4WhobiKouisXe0
# DATA db4WkUv5QS4F7vqun9bn7gB83g8PUulSwAs5Ut6j/C+5zcVif0MggnmzkvoZdGLBbkbFtIyHQwe7XQqIsQCE0TPNaW1oAdW54WXp
# DATA VE//XTsifU1skodIgI8s5IiDnuibXgad7pOKYda6AyWNjtsG6mdu/FEMVvTN5PoygIku56UpDuLv/ITEv6GxqgduHhDUZYC/VCTc
# DATA SIMQ1t1eqjeM61dPQuxBhvqGSYCSiF9XT1aH11ZXZ7kD98IfVJ+0VIhwSN6USHSkSkJiaSOwZJYjBpkoOGFF4/zmY/ZJ1wFccn3x
# DATA Qk1S+tTbdL6Mf8wyPFc4K5JJJbPY0leHjeylq0OkVEAgKsWRNhzMwRyyVJeglKgJe1K17DYXInV0avhh7DjLuEL7WY9pRCG0wjgi
# DATA 8V+zMHNfjlrastubJvQp4zxuCdCaBHCSz7TgSLBO7TEYEjD5BMFiYaWiLpj9WrKJSMxwn6vPMkTPQpVav8PYQCOIfMBG+NJH09ik
# DATA FserClmieWZCeRbirCJDEb0QocgXiHx2UkOnlYMSIWba4oZOw+68MEVP3HwqfDUZR3kT/1G7zck/5SAIyxMWr9Y9d4IQtHuMu4ze
# DATA bl40luAspL83Kh3IH9wdFud97WUooMp8r+YgCU0Tg4NphhQ2s4QFM6ELc/Pe3gmDJJjlQ3wh61qvmqoRZ1/T21Pzhr4+fc5nmQPl
# DATA YWgSNcpsDpcJrvh/DFMtfUUp3hxzHvvc8PyjadPBJvL8SThl3hyW9pdGMSKSJvMPvgGG4/cJ/cfV5/lhCvlzWeMqQAlnQ+GiSjsu
# DATA 6WjsTAe4B5DZMW4UFenDKFc9xad9kYuWnMsxVav2msuBkoAHTZOFhB+QtF1acF7oMmjRnenHCFb8huFolfRkrCQjMYV+yiakvo5W
# DATA kR4LRB/yACj7urjirE/OFCPGiYPa8XkitHTzpzii7aAAhTi2yWJJcXi8OXEH+iia1xJmJK720bqacLB+Nkpb142AP5cYMSCefIjn
# DATA +efCA4GR9DyFJaoPnR5TCy3M2BfJuhxt+HPSBkOSkJ/rrMuyHkd4P8eYq9M2+1dLNkhQ7YAP5J1Jhh6ioXVNVjx/a8/ew+Ahjl2y
# DATA nphYdJtiiew79PcB5M9tehU7InJdHRmqo4lc/2TcFi7XB81ZQRqhunvHg/Dd2xmOyX9hpP6wkWxoR9zZ3kWsnXX1v7TsOMtiBXwT
# DATA qi4MMnXOTg2QZvxK5AgM8zJrgHzieElRqIZJZZcT6SHZzW90fzK61YVuQeFDw2EmrqbDSyceg626ICRVLgoVE6PUEzqIHTYhlrGY
# DATA wRjEHovFEIOHSYRLR4vNZHn+xNVd4leOR0tirBlrkHiHzPIjXAvjWksxckpxksF2g8cBu1wqiE8tXzaC0aPFkWjwsHexL4rCw/2F
# DATA vXTIfzSg9FsK+Deh+yaYH/+oKkL75Mz7WSXvyLGM9Bc4ASFmgIUKIPSA2TfHb/g6nks0TF5EKtPfgaLOWPL+7tk/VBIOVo1qJp04
# DATA uW8hBhv2KOY3BP2dgRtJMLNvPJDZilzqOrT4zbHzVcLaFwx8Nsrg8xSP0uP2o27VKW8fiy+FrKq+N/QOQ6ZdKlgcG+2WXcrZEZpb
# DATA pxhm22L9EmduLgDEBU55QarA4g1tIwoKWFJH3zAeThS/Q7khIQGyroLSEYtE8geSkUM5gl/wB7P8ug8Ez4GkEGRu4En403y+pBxT
# DATA 04T4P5EzEQUTmOvpeRDLFQ0WytcQT+A1Maacks1ogzLCLVI7aK3MQqBERtZwJyV3vNPNCwxQW9Jg4fSAyEGC17li/SVMf/QlrFec
# DATA GR5VcUw/hYZU/vKCc3++vKweVZLlZVPDLExBVXGOoxNxqL4uqb6O+gj1fqJuCuIs4K8W7DeXI80sM6rLgpV2CCerpJ9oO2SWPaYE
# DATA TRStnNUo1vOk+6R0Zb1sk14jexWLb/a+UFt8Z3tv/53dzb3Wzsbe3nvbu7dRwU8NVbyps4Xv723ugsJfXorm5e2b7iu/Fi8Y+1hc
# DATA p/WVFf2jfq67MfszS6Q7h/XXr15ZX8mv/e3d7Xv7rc17t1u3t+9ubIG7c3oymYwyVTdsNbsi6c7Gvc07tph541e5d/9ma+f+zTtb
# DATA t2xhh5GajvtZyVlVu/JwtA6u10GYeve9rduqZxs372yq3m2+vXH/DiyN4jKm3XAgdzf3d7du2blud0576O6hX8CKRVcW8nX7tb23
# DATA efPd7e0f8oZovbu5cRurje4LVsirgwrxxLyZDafsHlHacCGTPGpPJt0xSD/j9C9h4sfdGsL5dOHkA/T4OG3Ull9NXb5N4+zz5xXs
# DATA BVgwa3c9Msrdg0+mh7Y8A6G36klAYHRlx/32w6yBVRYkAsH6X2sgIIWqISRXr+ErSRzgE50XEjzmgRbQBFeSwfT0sKt95OiHFor5
# DATA lRsNgUCyGi7Dx5aF3y+nD8YPBoCT8fKFPO8Q4MHoNW6Aow3D6rLu096wjMYrIawA2Ar+IFOitvw6rl7tM3BkUIMDa0MN/gbjVda9
# DATA drV2eO0qG9P0tOj4OcrL4jhER1C0uW68ad8vu+FG/O7gfWYY2Feqfas7nux0T+Hk/PTxZGd6qOj2DxnaS/VEvIaf6g388pFHUMEv
# DATA MjCWHNtCyb6oJPtnoyBLI62KnFiZPBXBXjRW/VNKpsj5oHUk7lMIvQGIjY/QLv8xpvP7gtWzGPL2RTxBBO/M45cNY9M4p/02ezCw
# DATA HWqk54yAofb0y7yHH7d7Ewr9QAJa4vQl4NM2nE4a66s2RFkAPaDTsCIHdzGMAyMgYPU67b7iJNNohEZ487H+COq6jU+0s7x7ckQx
# DATA aJJ0Tex2o9a1dwxXdLcA+Rh9lFXJbAWMakcnqqXaSK2/UXLZWqI5xlaTHzhlwgyga1fWVt9Yjx7Q36BTAXgRPAXZz0UMja700+Td
# DATA /f2dvaqNR0qNkxHnDpO9sUZg1mV128dMMnU2kyr87+bmO1v3klubu/tbb2/d2tjfxKe15bfwX3WXBu9SkaRIVbfnEC9oJhjwr8Ph
# DATA BINhkVVoy7U+98lIywdeuqUs69d2Nu+2YNityVBdq7v4dwk6oa7ecrmmsy7ZicKLA76kbEktDhdo8cvSURutaCAhiOksOzXUOI4J
# DATA L5PkA6rvR5u7W2//pPXj11e/r65nNWUbd1q33lUcg/Olusd7p9NTkdMEvt2/s/cjegB/PlprrbMzd7uj9hxsYjh4tdOhmmJwTyvB
# DATA HcpnkUxOJ2BKCQr9wFRRz09kC/mBkgy0axM9Kaq3AzCxKwmhlK6tv1FbVf+3lpqbzBICNZ7SOvjzPynV1iqmuarfFcg40s4ULX0c
# DATA ya8EHdAT9HjcHrWoNyVVmtRy3XFL04mGYa6gPkW4puM8Rl9tSX/HUHEgVqNud4yb5VBJ6WO1lsPxKV9EZtcAAdPbr54rVlm0MApW
# DATA /xBc2Jywwa850fjfaJxHiQCgFrxKBx5xwD5KyzlSC3U96wI57ZeO03c29xUJg3O0slZbA4bgXTU19eRcz9AMnt0yS6kk6z64CwDn
# DATA oP5/qtOUlct5s7e+ugpkrIe6H2pekc9HpdfX1rWernywBnlYk6urq/kzJMj9nOzGlWQLHIZimY5BJLCbGLZX1u92R6UaSz+0DC5Z
# DATA iSZ7B7Ce3ycCRuAryi7w/Bc3tFKNPOB+oRPW4JpWomQZM1D9G6Fzgq0Umb8qqRq1NR9/MaB4ycogWQ98C9S1JU32cwVB5GHU2zTF
# DATA u1fXoTPhkfB+nBKSG8RVJat4eleVUIXXpv6iPAPSc+PBQBQ9qNebueUcdvc4TVM6mcn5+ZKoYjroPamvPGqPV9S5WzFK7JXxdLCC
# DATA E1GDww1VJqhybYGsPTwa9m8sndPgZlpIV6cep8Ju6BtkJcn6LXnFR1qb9L1bPfplCxj7nK9H494j9dr9Vvc1S5BM19b53ytUBFil
# DATA 9WQ4uLEkhoDSVZYMj49vsA1EXZMr02y8oojSuEuTsnIyOe3T+/Z0MkSvOftJF45DCyP2r65eTVbUf2rig05HCW/tjlqKH1dv0c1c
# DATA BU60uk0CqdqT2aB3rLjq/uP2WRZ8tQsYrePuuLozVNN/Bpx172jCnnzVxyfdQfVoPMwyfuJU0x+SIiT5y/+erDyBCQBvmRW9KfDq
# DATA 6/cAUF9dEa3DYeeMuKPVG+b9w/HoqEXsCl0qyZXV1cx7D2Sv6D1QB/xLifpFWxC7iFuQKuCk62YYahQPHtRKb730uNvvVzGN6EpZ
# DATA jUbdbIMzcEW+EXwCg4VblbwSklen4x7+ZyVpqIXC8ur/qfPC5OB43M1OSjF3noqx/mp7prn1UnP5NlI1/NW0QsenYewbyKwTzcDS
# DATA vqYpxxrqPUZ6pFpYwxZQqzXoTlqogKCYNW7JPoVLkx8i0UBPTUUc+scQJ9NP5Tuq/urVK/ppb3A4nKqlpRfX4Y2VLNw6teKv5NQt
# DATA BYy4LAxgCJ+yeZ8Z7Q/JD/3Zl4nLgKJYnJaX5qnA3X41XDHHJA8QKxImX0aAObyCKAjtFybeIcIZ28g1kB2/1EgML6S7tmtGf3iA
# DATA N0AsiI31Ff6SRhYzjBiCaDdqgsLdruRhUSIH9fNkY2er4qwPgP2wO8nT5Mfj9pkVpb/iIDcNTgm3ufAJ6R37e5mCWcyEFWWrxFgk
# DATA CAm8p+Tljdt3lbjkInt/xvzDJwAsBDL9xzLk6TNaaRtoEIPNMi5iQQxoADCS53WWr1fqDx8+JH+087SjrjV0C0lBQ1PlfCTpcKQ9
# DATA QM5TRairQKOh0JVV1I7AIyyqHr2eMgGE0FiUYMDAhtle4fV0oIhgVs0mQ8C9hI+5efWS/woUlGwCh8Ydw7fxMma7bEc61MyCaqb9
# DATA 3mlvQvUMhtzf8zQbHkPP1lavXn/9jWuqQ+ra7dgHs9lsMT+p9mikUaBp6EylNfqnRj8nV1a7pDrnTLlZiXHIsFxZ4+DYyll1raWp
# DATA I6WPf8bR7Y0DtkFXSWaiew9uOmuaJt/WrL6iVnlFjWKFH+TU3OmCgTFrDQcNaTrtHOJsKja2g7YjWGw2pQAj0Z+cnKUzx6pKJvH5
# DATA H82i3aDXGGSu+jFROwx8kNJbd29X997dvINAw0cAI1w9zvaQ9VJXP1zKfbg0YerWVqgO9DxHtHo1J9CDtVW0WjA7gZs6I4Ow4nzQ
# DATA 1+kaXSzjSWukRP1hh85CJs3DIU0JjLagghypdwTOeZAaApI2Y1i1ka1l7CP1teu1q+mlNxmJkCenyHw1UiXAnR6mTlZhNcf7fwHD
# DATA vL9/C9bR7i/dQ8tSCR+IguYWWcDRw1YvA97vLKneT1599dwxM82Sasd5ePvmLFjMK/PWcn11JsM21J7MmWs6MXxw6t+vtvuj3gDI
# DATA 46JnLW8yoB1134jvUTSAblarmToqCJqNv8i6D2hdpJWmp4r+nnZP1TpXR8ii07uuOkZ4qLAMcL3UL/jtdY3/QcbXL652OBL5N954
# DATA g14BRYK/VnMHlL+01immqvh+rC9boD+Q6OEbrqzwnRNkS5VSU+qQJSRkAmE2JFj4rxOkFLLO9fyMKMTy5VsF879ESV7rt/0XgYdG
# DATA 5NOGZgPAmyR4Dc4w11crieKyZ7m+SMyAFYMfSxNGjO8iUHCtOomkDP2C2Nw06sKSHUjfnMDVrRk/v+EahbuXOI0G4Wmpbw8074F7
# DATA L9fprh7zuItcWwXUWX6vKTVwc8cU/eK8j527GJsQrDBwDGvRYxu/1C93OReffpQ74NyHdm3m0467EL/0Ml/ZdjzQ9xUkAIN2n+/u
# DATA l8u1yQnkwW28yb5bECs4KY1rw/ffWq2vlcu1IwyHKpW9EupVHv1yqMzr86jM2nqEGVh3mQG+IYD2wBGHqCcPuMGgW1sCaam1Ycjc
# DATA yEgQ8CkSDGX8es5Zobc5p4Le1tftbeZe+u9s3968ef8dGNPptD/pgfpmcjRqrAITwJsuvb5avw4KAZDc6yS96z9Xpp1RERcQZ1qD
# DATA 43ELeklhDWBcr6+oPbKCXV8xr+rjocnFVIX5rK/Af+0zUrHWV1z0Tq9xHX12LirCMDWvGj90zfiLn1MgvnXVT2S4m/4TlpkBqOq6
# DATA 6ZlQgU/GbRS1zepFFpyUuQeWWWSfcnGAI2AUTiE8jQuLMIqVBW9EVuHAhXV5lpNZ34bD9hqtjhXEeYyVgs2h+Aa9LaJaPcxN6H2j
# DATA ZM3M+Wj4cCWbjmB10P0z1uWQaIPVeAXmQTNesW4wxcv5+mg47hq/4tjnsI5uqWacq0FFEqxhbB813XieiOYJrwGyKYj35VBo0fu2
# DATA qX1Ng5Gh2Tx/SSb9DM5q3t0uTCR5RAvf1tdq69ct3YptzqWLURkyQMD5lmSGNPDwtNZZYXswFkKCU0zZLjk1F611/gm4YIWPHz/W
# DATA FcZMEdBHj3wKkiUX8LL0cfYiIqismmx+DFUQRBVujwgkDnBpXpgVJrD3qvbDqDAqJhJDRZPIXBJ7t9TlcfUrRhWDKWisgznKKiKm
# DATA KXvGPzmjuXhyFnaXYrPqidbnpgitKHqKOB4GUndBFRl72Ui+9P4YuGs//KTQa/JCgpcMKD8PM83UEzJPuG9o7AH7XHSIcrKu0D6E
# DATA jCs1+M/VUrk8K4c99LFoNGUtlHNiSFPOeKW7VcPV8pNGXjtGNUgn7Ojsy1Rki3T2XilHk1+OOUHLID3YFIp+OMEihP9QIVzxCljO
# DATA ho99UxLba4b9DlD3x17QAEM0VtxUZFBdWfqjAnutanBCtFC1ABx7Br4lJQpahVPx5+/ttxyH5RSBkm9v0V/opSv9bOFv7T4L2fBs
# DATA k+dB1jPCRNW/Al/kSsyZGB7aoAb1y4lBcCNlwtgiNWyKknipAfNHrpHds/wk3//LJFf44tnvOYoIMxZhMC3kK4oEDT3/FQEVQM0U
# DATA 2ai2BmH9kL/tkToEQ8jkWToonZIjIJifIQSCf+4Reqp9cFsJjb0BngbxdPe9lAOzEVaXYwTvYnOc3aKsd0yLeoEbp2V6RH/YrcO/
# DATA xa4BPyMl00MUmoaAhROMVpdhVuO9xv0BBO1b9/f2W7vb27giqEI3N6/qrYDjXaG4W1U5DClFbZdF5tCvKgltfQHwhf1h46YdGVuo
# DATA 6C3EeZpx2uW1z0BzMXzULfEHVP0rNuXq5GTc7VoYwyrgwSKWLl7A3OJp+yw57IJrQLdTSzYRTkXHMXGFWBJg0kbtw16/NzkjIbGi
# DATA XZTR3kiMmiIVqAcDOougDpMhU4peptEPLVQCrdE3jQqN4ifoqdaNcapan9AUBovDnoShY4pPuBrt1JeDc2lKitXUFUC0DVgbce/Z
# DATA p1eaGu8Y7qtIXJUfpiebOlhv6v0Tx2hesD4COdY2SKp6zWMDx11I+IvIrFTcnoCafteaDOlA6Qh3ibsAl7r/YS9rLfRtmIHGBA9w
# DATA r2BtwdisH2CsU4YReev48lL42G5t4FrKdTmP15rQTHwFDvRCNcO1CE8x/jL7VuwiIvQBHYiRd0ofR8ZozE0XIeyRBAZKXKfje5f1
# DATA eMAZ3FSbFXCW4Pet9mij0+G/bo+HIyw07j1SbDWYaJvOTezd+zaCEB05wrq8w6TojLxodBhhPTlHB932qKx4ISXU4+aDqRuNu8e9
# DATA J6rmDXXhc9h3GzE6Sl4QPzhLBoTGRKuqu8aNJ4RFgN7QhcP9gn/sZYO/xFUTifnUI2Y6qStqmOqTDxRnYRUms8UpgWwCpzK/jeqF
# DATA 2zApDubOndqhgpLnF4w6f4T8ia3AZs8Fv8r4KQNJEutNc8TkOorSoOxliTmNqHIgakyofKIFQ6UNYuCJ35Ulk44QslfYNBoxJAs/
# DATA i8biDiEau1u/d6G7bTV+PUXA3S4uUDRWYS6Mt++fxFrJ0gWhNMqL40dJNIx8nNC546WULwIiw6DAfKaTgn79/K+RZ/7KZHrDhx9h
# DATA nrFfOaQVvT0biVQzlNL4nQPbWwqStZPuEycVynkhrssc7Qh0hJ/Dn2WZHEAjuxybnA8VQ6Rzkj4EMX+IV0asHN11Ls/kLbvk6W0C
# DATA DAwrhzcRIUHkoxCSXU5pzEEN2q2V1PVD070MYRrUMkEQgy5QAXGnwfcOtlJHvoKucacxiDPR4ksF2bd8Aewf3VMT7Bqx25zE1ZjH
# DATA KeZXpl597IppnMKiGOTBcHrkjYyrHcA/Brmsv2l2DfrhZNegP4TKxE1UYSs2FekNausQVc/crJuqLkWDj/rgHHxPJ7TYb4+3BsdD
# DATA gGFF9Ef+rSmvItgtVH50FdfVnbTBPlQCj9OKTpVclimXJwitrTrSnqhucAnVu5Y546YWAhVVs7IKexOqrIE7jqPu0g8BVB1wXpfX
# DATA ceNjM5D/LFnWz2MXKIyRRTruSaIbx6iLbidDaTBrH3cT9JYTSnr+opbbc0wwrDqyZCcKLK6tkTo3eROEAwrnUxf0M7GihUaRPlux
# DATA Kek1+nAwhZxC307DuvK8xjPF8EM2kJy2OeQTCzGOHAGRTqCdEepKUKS3y3XaezhmSsdcA6qKjyYy/xa3BPaYbvu0Yo4CrE4Ll7Ox
# DATA bjbIFU5QzC/WVtX/bF7AmzAxCQUAkKqhP3yIuO64WTjpCKBgItLpQMnusHHQdx2ALh9Bp1U3uiYvoJvsSFIhfUiO8DJoJKtLJupL
# DATA n8GhOuUl+Gt4+NOGHh4ZesYfUIKinjqjDf8QYxAYT4snrXfRDwZEDv810Tjoy2uNZM0LMhqjHokEYKyCwFJJxAsxUqCWN+VEw3EN
# DATA v1ZMWftQsW3TSZc4s7RWSwkrdjzJ8q6L+wM8qIPwVCOYrMHmwG6k5eidRr3oZcQTatd085iRDM2EqUe8ucsFvTKbeBAjOFBP2Buu
# DATA n2Jjk1XRJNM7u4uVgIJ7Jq8HgswFVM0cpAR9mN1udOy1DcSM2ImfDnsDzAOwTLqC2DSKD31lBe/0BfqqZ4igEBQFUFutI3mcnCnj
# DATA xYsiBospjMff6TUzYbSWFdXR+i4l4l5GwhDlJJy+D33CE7o6fGN1FYJFAEkn43AQBPRuDd+nkMrFhFiiE+pMikHlLZ/OVfYN+gHX
# DATA 7cl00uvXOr3s/dY0U2KbXs3aMahLf+Ds0NeSa1fzrl8701vqdBwf944g5glwfN9HIqvYrFMkS/6BlnQ/qorTtzJfB3heqVfhaOgb
# DATA jgS8wIbUEeTqy1N1/sEX0638FYBQ7k8zLAwhwnCAGCVb7eEpmbb02RdI2foCIbNVLOwYulxxVhbvgvTJYYrEfTidjKaTeuFmPDpR
# DATA G6CE6y/OhEGHX1tbI80hgs+Hm5H01CS75G09G2RtSsfP22EfwhuFcrTdKUGQtPmsklx7/fUr1/KjboHeYC3zQo4jK/lYzdhkPB3A
# DATA anRyIolpRmsMhA8NxcvZaalSbqqcslzfsdofJxHI8GFWO87OBkclXU5N4mBYcq2KeIMZa+LoLMb1CHWJ3jYO7VV/k3sCKQrQLWyU
# DATA CjULujsg5DYdFJAPa+iqyG4M7D9IxmrtTLiD+xEqB0tRB4Le5dutnU183h2P/efM/fROMSwHLDBt0KLW9uFJaQ08cXXx93v9vihe
# DATA 67S7FFsDZEs8R9FXA5BAVKgqYvThTmR/EOZfwE/qXtDwKoEI6cOow7mELTgde1RGd4lfLnlgbGaoJZmTR7ZdwxB18brTaz8cDNVR
# DATA P8LEwrawaooOF+aE9hM1VKgrmWIfKQF2Gm0RKvFbNH4suhxAoZQE8Il1tCNaCb52t4bTfodhoxWLhawyEAvk8eQYEDKQ6bTzRkqB
# DATA NI1sD8KobsO3UZMxgJpbMrcYAdWkt9oDFDrUpdM/w4Ml7p4bNvWZPSI6KUQHlOeYVAFqCqUls9Fv6eScO/SAT4p2EwBfFDFKDdCt
# DATA Gu3LzYqb+whwfuTeIJdIbGY0hF0Tv9tydpZ8FawhkRqdSVRqZymNuqKh8jirnxUiTFiokUOjZOjqQvmJX0k2Eg6V09vitP2+khfp
# DATA woQYPTCt9ol1Q6iKXpd20c+mil2CrCHd3gisxVzf0fCkiwiMemy1RGfwTN7vdkeZm/TOrjwlzFBkeDgFNEy6rHuDzKCvqDkoSeLK
# DATA 79KKzUrOyskm5G9A93BiwhS7q0bcbdENwA8B7UP/6R0u2ykHSMp0holFWeRZ8/SLWx2CHwp6BmKHVxblSamB3p0OBsgDRVILUea5
# DATA z0A9R38ieASm1olp87521OKcskyiomM6IdL5fZIXDDo36zwrmUVh1PbaJOvwM8AwwofRpMIyYcGlcwpj9Z6p52K5Qb05flqkLxXq
# DATA 9ohMYKQA4XuxSAJnl88AQFUnGXBlbmJnPtOFxnmr2YbJZ4VsjhWZ6mvmpVuMz+ofEN/7FwtMn9XjBJMoUgrCNHUYOF0QTeecBTya
# DATA q4WHGmpEB+HarnvSxm0iMpkVmQcdSsypJCoQKKY9yIuk6GDSPsyA2vW7D9sIXaHRCm1ldjvjhUas1QpEvcFlqv5EKY1ZlqyW3IM8
# DATA Qkn2GE3XSC37CDBY8+WtglvfmKFwoMRpYEyWsx+c17k2g3+izCaf0bkgo760QX0RXVydxIxw/v7AkAdf6dQe0fwpCJVAWRX+zuBv
# DATA 5Wvw/LxHB1ofucx7aPywPzwspctp2duxoMvjZJm1PuGmxdIlRWHXTEJcY+V0M+SWiyaSrSoacA/STD4FUGyChYC8k38wMGxg+/s0
# DATA nNcvYoemQKVotBowaIMOJ0bIKjiSUPM0jKi+laYAoejNHfCvc7eE3hGfPv/587/VqFRRTDrYY7gp0DfQJcjeBOCAPFk8WCw9C4XS
# DATA +RFlvB4AIFspRmMLqDcCNDtkGr0i5pnvyxIGGyd+zIka8S+TRpxywEYS1jmZPGPfOGeGeDqQpeDgMLqiQFIE5UpvOM3SsvN4TImL
# DATA z4ITRShmhK2va5YGdHof1xHTuwU9TRguDc98g39xlyFxIFpeXaUdgql5ZQmPLVKau+QnxtSsxbWrMxQooMrigx7NbMl0DzG+CHKF
# DATA MmIo8volOUlh5mEmrBqQRZ2ez+BR2FVnMmCTQSwFYhCsqFcrT8btM84MoReFhn9K+JjwyeF00OkDssXCjj6y0Zfm72xEPqYZy52w
# DATA v/dG/bkeM2XfZW71C515gFL1yksI8hKoCeSEvQ4bh0l7vcRbfn5nP3EXVvW5yWqAKLWcINbvYHz/6APIO0WQWXUoZIZItxxxv4VT
# DATA FbmNJWicvI313Ij88r+hVLiAFudBfto9tmT8/jLKBQiLDKEwIm3hRoLqNsWGIcOhxOKe1DuD410yGj4GsW6YZZDVGHPKtcdkdRh0
# DATA H4vKSAYQLkQJIuVmJ8jRPD6BpAtamtSWwfbgLGHVCvjQ1oTChmrpEZKQwLYCzlbxBnh/O3wDMu2WVwiuDeHCIT9jn3PRoOO0gVBD
# DATA 5LSBf7InKKgmAHyTUYfrvoEBQzBQiaWmH1V/nP4vq223dm9v37vzk+QD+qUZc/Pg3vbb23fubL/nbslJjLYaraht0v0q0JGIL0ll
# DATA Jb9k0F5Q6baUIK+EY43Yy/mM6oGg+I2c3dkebvKJ56Pset+ctjnJR7qrK07+vw//AfkMnfRM5itJZGZ4jUGoI1JRU9vVzCNdqyaH
# DATA T74LWI1QqEqef7dmJ/yUDi0GSTrwgaEJFYuEQnEFlr0UEfC6glGOzOTBA59o0W5dimXj1JNLeFy5mANZrd2hUE06IPYQCcuzl9oe
# DATA kuLZFLmQ28jNEU/xvZZ61pfyW419yfhTSiREYkCLr3YWJnD8Elcbfeief6xzYeL+cXPGPvvfBXkJbQ5NmVXXC3fD6BwUKXVaK8gc
# DATA tHyQJvh1QJBkN3S8YLMZqxVQX83l9O/k9wg5eT7UiG3ol1XcGJExM6HlppOG0Dy3c0/z+RqYOhIZyADiCjLmNpXQl4mfEPrZ5zc8
# DATA 2Dm8iGC9tBDoJR/khEM1NpKI1mEG8EM8wR/huH8O2G3iZqslGusOb0lV6ktMOvYh6XM0psjTnKSHioBnSbXfDnMkkOPmH1TB3xAo
# DATA vcmTWMMsHib990dOBkEMdUIAEnaI/xS3E+Un1O52z76ohQ2mtBdlMnD+BpOBc6UwtbhD7c5klY5BeQgzNDz7fy2CrBLOXG9aTIOo
# DATA qgwrpBj3sDbo5Oe0LX3PXLU5w3rG3YdKmgHxID5oOq1QhRId68lRJ3ro1MOEtMM6e1QywogBNCUyrYejNc10KksMJI0f/GYkMsGC
# DATA RFQigCoGR6Oqs4fUJk8mJsMXhX1XdIR2hYKqKzyLFZbV4A+IjXajGFziRi498ZTleDpkjiY0OkbmS9dTNq5lI2K6mN9gm/y8JPGl
# DATA XD2JzWUeTwXuuNEiYfZVJzqf8a8hcTHlByQGHA/421t3NvdghgNmV+Q1DvOve1jQMm20HrIFOlaz4V4rplFYJ8CwBuedEk56mZNy
# DATA 8F2GCLrFd87zn1eA6vy1TdD8hUzHGifkaWp3pt3DuD0pGlpD4DgGnyPK3RMcOHAHt7WoAfi6Aoxtgq+FCKONgfaFWXzPMIjNdMeo
# DATA rUW9BH3iiUw4Va/pRL26J7SKtgqHrcuLlFZnHX2cP0TcKMm72U2BzExOvWV3kct57eB1qu/yxE0jZcBKbRsmiMDe5xRO2vT5sPm9
# DATA y+eJwgmF6fhndxfBlbbwTDC+iqdlw4R0/uAkObyb41SEFORhd16Pf03XM+75/xGB/6ozI/Owu9CeKN4XAmfMm5iggUU3h79BgiYi
# DATA e4Ua8zg+e9L5BFt2Lbg7V4L4fXU111io5VNdPqhfWXdvlrlnONAC8fpHjzMvMO2I6UCH+3bSeZWKDRCM4wLLvch+jy8r7fRYnQsd
# DATA dTvq3EMuhiggt1aQd5U83B9Ig+XfFZ8w/vCHqJ3CoSX40ec6M/yzL0KeUbfyg7DGN1fIZsVwU9XlFWajYZ8CI+3xltFs9M++qIA2
# DATA yuju6CvIBySyuX8e1cqFnQVGiOfj3xbgRwkljXe/FuKLGM+0YiLkzbQ/5bQJwGJwyd+bqCoHKTlkc38tBI7PWYL5VPUNs40nMHDs
# DATA 0G9ZhEBJxM4SC4TaRK+ziBubj6e9U2yCDqV9/tdaFmLTOqoNDZ8i0mExD6NpRZx7wY1puRdS5SBME59a9Mceoy/oQ/y7tjF+OIWm
# DATA dvCN0QSpE9totRQP3mqVxZcgorfa/EkpHY66Yx0mdXQyBL1IgzF9MNdTiqFkGRoaOBEupeBGWBngcarMbuM38m+TUxfjBFJG8mmP
# DATA NeodpvuCvx8S7h3RrxQxmbOTKp0WLIsJdsQDhyoBekzwkFE3g+fcPwCY6k00tg81nk1ATy4eaZC+KkMY4Ij77YFwc8D6WRnqPda+
# DATA U9IpYsy+N6YmmkBoqModkHOT85o7H3+px0FvnbFj7gmzOha0AcUeVBNqf4XoTqlW2YRWvpFXgC1y+QW0l1BhM1buk1vS46fz27CX
# DATA SWErGiCqoLOUvzf3PS11/nveSoSVXtgXTJBcUNOYfZAgEHP8MGuAYrxwbGpvFXWM8tza1cgtKfRJZvWLGrYnhUMDG+mcnuI2VZ9V
# DATA dVbLNlrGGilu4xZmxCxuEuHHht+8DsBCqp4SzoHddnnZJZpiiLbMgq0wprKpABNd3Cj8jjGYgk8pSUZRs0QK3SXJbcuvHjHni4lC
# DATA hBYvuPjOp3TaFuuly5UGXV5bnXv08WKyq2zSwqM6heGnTY30dv7aXmimASI8/y1nhONG2Zmdy+I/UDqzUf/wq2bucpPyg+9wy4T4
# DATA mRxRcMCPkZqVNcpYvEq+JequwkbbmPy6Kol4QhG5xdX791LdC0LWgo6s0cfGRL+kIGLZ79qBg+InBP/uoH3YRw0JJB1dDFYEwUss
# DATA gobaRRt37rhwI44VSacBQHkENXTO65FFT0EXZ+P0L5cacMdgyqi/NssM9z8KDuxEbDudMAB0dhQ52eThsw7giWAOAxhd0Sg7BAjD
# DATA Yf2LzSbYt2OpEax+UCy/sWi6gQdmEZ25Yw3mmdoRlP2cShFK4mCYFm9OyZPa6aUHLXjZJW/3mgVaKKzP5yQvtNkZAyIPS4Qv9pa6
# DATA qOh7flCuJLEuLji1ooj27YMOFA8zxh0LN6mIy/0FiUYhny2kLy4m/fR1MXfYF1lET46QawgvWvxCkB6uP94Y/2biXzFHvbgTvugi
# DATA Vc3EATnduMj+jMgY/t7XBum8jSW3KqVIQQwBri5cbefWkPcIN2f86BiCiJRpFU+Jbfe//cx6+ruf0ugjOQJsR5BBL0cOFrPSLXvA
# DATA 7EeCeW45WzlwlS0aWiWZNwLP+Y8cIHuD0XTiYGagO0LdWmKAnyXHu7rjBIUvZ9FjT9Ew9tAXUAX0/xa463nbrEjWdZKRYamFdtBC
# DATA R7awOT69i21XsVMXOqa5knl4bqkDDjItFhXdwMWoiCPI/Zpj7FPVleZMlKt1EWtB6Y7p+YVIitEj1Yt2jy5VmneLCSzoKBllqoeW
# DATA mTljDVQ9xT3k0i0uXdTTkIbgD/5yTresss3nDioAzo4YLLpIbGtedAYZ+N/vs+E68ScxTCWz8wNM5kLa4DMVjqO0OEo34lDJwJir
# DATA gd+Ie+UAT2pMC6JZCRvZjLI8wuV6zrVoVJ6FW4ROripWKjqZhh8jtG/6QQiq4dyCbD1nv4SyeN3nfo2iOUTgjjfpdLF8kQ5oHeyC
# DATA fdCJkl50N+auldPW3CUzxHMBWXZu08iMQpP5/pcU+4U4tOQhL7bJIn1g6He7BvMYtt4ppofKzmwUsvq7Rq4lgwyypK8KmOQW0tdW
# DATA S5wxjiMsB3UazHHHnWa0QhkNCuyewpV/EfxBCMH8Hfp3Ya6pMELHdERnlcQfpVFF58RwNpv5zHaVAuJcPJEb4r0JfHn9dZ8cqjKO
# DATA C5KTEDwkBy5OuyHFc7LOGmzcOVuETDPh7aLJMqUnXui6NQke5FVSSN4oG4EYj1MwjwREMntFXshm3MSMFVSU2EYHQ/kuMrnRhZAP
# DATA HXx8P/3BN7mh3Co2Ad5pBwIfKYXCnGoWuIVvXO4O1GY8h2EOMP8D5mNhtkQrt4xKv4og5A5qg3ZGM66c6L/1B5MvGLy3isCOA+RO
# DATA Qx/mSSppPdDGcXKdGPEIyspsPM4H0TQ8+ivYWnVKBWipf1iKjmDdTQwsX5VjmsR60hupGR4DtkFvZLha/brCOeBlvHTeJCEG45Lv
# DATA Ex+oX3XVDhyn8JLHDyuIrR4Cqud5x/vMhTofjzhjNUjZ5DEvcEycVBq2BuFZny/KoaW6PpeLXcrJTKLV+3VP4ZOSFaQuaOgsXDI2
# DATA B0pMkHosywiX2wg4aFHJfG54aUm128Kt1Grh8Fst2KStFk+AE9JCrgpLAigmhCIBxBhEEqkXMR36jP/z879Vh/c35Bae4/cy10ka
# DATA m1P0BVOXATtDYdYC6AVhU/bOskn3dJMyBspBlH4EuwJ7X0l+2D3jvyCzBf+5vcd/IEbFn+9t37uNIDT4tCzDtbZQNYP5FXqDo/60
# DATA ozHAMGlCVk8GGHOO40/G3Z8S5AbnY4eItWm/n0ADtW95+mrJs3+xwWzPf0GAFQwgYHzqKy6Gxc8pGFDQZXKvdzOLPP85YC1daDX+
# DATA 5L/U/9ThOezDhahOR2109q20AVHg165exX/V//x/V69duWL+xudra6trV/8kWf0uJmAKHuWq+T/5v/N/L7/8MpwPRfTImKlj3TC2
# DATA TCdeIV1aD0Dyxt1+t50BrA+FVK7V1mvfX68tLe2fgNOqLPizqeK8k8mJIv8In8YREQh62XsIeVxOuv0RBl6cAFUAYD71djh9eLKE
# DATA hYyckOzf2qkSauhxtw2oPGhIhKBQ20fOV52ctB91Ve+64EoNdrtOTfWtO8Z40466KQ/hhgRkqcHQGGOPJO1HiNIn3aMpRboDUhQw
# DATA ioTatwTIsfNumoAspPvzxnOi7hrZ6fQ7IiROQMrRT7P/gPP/xrXX1/zzv7565Y/n/7v4XzrNusw3pzeWltRByCbJebIz7mWn7Vv9
# DATA HsrR9CuZoQc/HutS+mcjfLhyhGXS8g3+9qePJ7IYcBmPu4dkOSibFvZube9g5ottzLKEyKV/1S0dUNaKDE9OXeNf+96RWR1AzhTP
# DATA qZPecrKLwAmc32d19tzMLwAcvKqmCT08ng4IimLcnWZwO5bGw8dlztGhE8oNHyd/+qfwT41TmDjBwbIhdPNOVWmrnoHPuk9GaoI2
# DATA JvjpAFilDz5InBdvYnq528CJl8vB99mR4vWzmqKrDxHHocFzqp988IHDai/0zWvJmh4VF2XGL3NDNXA+y26nuCZgCc9K+HXSeDNa
# DATA Ff4uq5meLS21IZw8MTOupL9HPRAxSrS7KphbQufp0msAyriXVv7yYLX6/Xb1uHl+fVY1f1+dVa+aH1fUi+vfbx82nSf677X12asr
# DATA NcgEjqkQYf4hAYOYOMgLMDzWWcJeIuUVJFpIoTA91nP3g+TKehnwMtXOgHVjMMOtAcrj+p6iC0Z911GHpteGlCE3NHqc2je0l4p3
# DATA kiyv3cBAWAKXqYSmrdYe9TDbY1YDjKf7g97PpkqcSx7DPVhXxxvHO0tm3PjKSrLbzaaqbcyCk7Txwq6iqKUxpiraNQGawz16hpcw
# DATA YCr0MARO9bDdB6CC4RHfo8fJuPfwZJLVzLKZDqtt9pI5X/ppWa8wTr4/lewGlSAtSY5O2oOH3c4NbYREbkDtnwmJITLCmBxbaaiU
# DATA M6SvlhNqb9gZVAuaM4WIHQzTh9m7RQ9pb8KaVRJ9auv20MJ/aoPh4xK4ya+tJsvJlWuvq/9ev3YV7zkAycGjUU8OarUaHSCOUHHW
# DATA Zh9YqGG/kzwct9VwSOxSkr0a+WgImQIgSR2gik0h6/wEUY07Bn2sptYWWApd25Cy67Vh97SPDAgZIq06iww8WA/36YSWGsfIbFBs
# DATA QfXfCxEPMY+0Ejmzr3URtHfPYc5nFVyJc549MXmzmbPMTKzVlVQDjrN0zkum7rwxZbwHwgsgH32I0tnY2RIBG722Wsy7YE047g+H
# DATA YySgtBU6G5i9BRBxMYPiGi6m+VB1J4fCv5WcA4JbG7TTdYA87s4StaFUwaAl/XHY0KyczCrCnRCIUEWd6Xb/4VAd2JNTNZJ398Bf
# DATA AvdQAZF9ezjeIrIUJbcAgTnooC5RUt7goT5QR/127zS7IcF8VbfoKWBiqlUgm7ytwjZ1broPx4EH0FQDUEfhCACVVFUry8lG0ukd
# DATA HxNWKOrLERNSkZz31Y63ZBVSm2SKjMFZ1Fu4liyvJDPHosN9U1uX/kLDMd3lsBfgBV8B/B7pZkPeA+IGxPP1Im8l0ahzXiz9Lzw5
# DATA kvRryg911eVozImR8+IwPmWTmCa4nEU95o62tc3CkzjnfsfdSh1A9rFG+bcwwVJnqpZGEWkNbtseP3xEyQsbgIWt54fmhWoHYDF1
# DATA bhQbcu5uyshMDomzBGRqTC5dIp73rRpV9SPSfL5VI3b3rVo26oNcV0sBzzV56y1Ij/NmI3kDznig8lVc7GgCCQBhP5YMb4xQNe3R
# DATA aAVV6jTEbEUz1vxRdfQwLdeoNzsPy6XzaPyoGsSAsLr2cGPWzTypi7Amk/5WIGNUPVmvzKlnn+Bt7/b6ijeuK9LTWgVQ0l6n3/Ve
# DATA XaFXQX0zoEqUIZ1Grlov5XWrXMu6gJu50x631Zai6GDKrl6G6U0xLO0IaJrbElBQSJejdrviBiJR+9i0lGdKvNZyq2oa42Ig+RzI
# DATA bXaoUQxPD8hM76+I0QEWCVgRIm+Jk2M5PBDlEj8rIsRynqyRfe/+zb1bu1s7+1vb91r72z/cvNe6f3/rtlsc0kaTIb4SwIcXVLe7
# DATA eV91GSu1Cs4acBQl4rjUOfJwz0kXT285ElB8ilOqDyAeM0Vda12ayjyA0Ge/hUcIRwY2chPS/TcCxAENZr/DNH82SDoI+I5rhf/u
# DATA 2T+gzS0OdebDc9Qw9EHP3ZPe5BYasZM1dS2JkTLsFY+VCfGr6CCGx6lE0g6dcLjah5Sw59xugUpsN1S0nDy7sfQd6H9a9vS/UFVw
# DATA sf5n7fVrV33975X1N/6o//mu9L87yEfZtdderJgzAdSs6tyiRBGoTxwpq9tREhgm1mIrD1DKa1f1L1AE6b+H2RKiGoOvTr93qM1C
# DATA 4CWgi4y7+i8w75m/Dbi9fjLpno5AvqMKp2N1JR1S5JGuFVwy4LJeMlVTLlWOWSaXKfRWRY9i0uAedxbB0tPQefb3vZt3tm/9sGxz
# DATA hQFkXocShXUg7JUTxFC2MGFXJGxhBNgDZGF676UdEQBbUKi219ra2918pyTRaR24Wp2TD5JNxLIvWGNhKd2696ONO1u3+VaBoG8X
# DATA 0MXDdSQcH90QsMUMD32+ilOlLvCueloqz6L4uatvvFGe1yPbk9ZduK1ubrZ2drd+tLG/6YA849XEE2qTa7zuJ9cwDnFLjqM2rTz+
# DATA 18ntgk94i0QLO0kThEsAvkVXBFyKvvkgXIg5i6DR4Wm71gL3P+603sbkT0N4lVr2Nz4sud21JXWPKTyLkct5BPo3DGJ99ep1TAb3
# DATA 4AEmCpFlIRhtOO6UjsqgD7sCj/in4tLX1t+gKCz5VXmR6djZuLd5h7ipJco9jp4fMo0MBkpxR0AiaE8nw4jjg55MAiLx0VBQovTB
# DATA jGReB57N0vnyMjsf6Og9jFhAbwYnYm8WnFxbHc/1JRI7xGdLUZ6NO3qu7m38aGPrzsZN5xjzvGUUfChb5fTpe93JhFOmm/b5lUlu
# DATA 7NdmIK+RPEjsM9OcTvTNJKKEmaoRz2Tc62A0bToAd8Cyg2eNbZBC1O9t+7RLTqYAxA6nGnLm+jOt+xfLB5EebFT/ol39K8Bntn+2
# DATA atWmol9qo85SUuxdaNLvbe6/t737w5zJt9szSSGotb6yonOD2xxPgG/HWxSdqPQP6bBmJoMXCPj9ne1ddLulOGjjTCk9h0T75k/I
# DATA B4D9kOeYAg0x7pb7qF9hXeo+VVXoW9WSBn0M1ZsaSm5yvVVlCJiBYb6GzEBR2Ao4B+oZ/Na6Of1bw+Lp3z+bdinHB/w4HrcfIvNh
# DATA Cqsr17SKcLDUGr6Ey1/RhtXLkBx3YC819FhMRCvvtqK6393f39njmnc3/9v9rd3N26lz6xid7dhu64quWlH6nd3tm5tAxhSbRXoL
# DATA nQxVCRMb08nJcMwyaT1JbyqBWpEZxEHyxb/3Nn602drY2aKbRokX6OAcLWVmgrH33gPsPbODSTHFvThIf1xV0svj9rjT7cBf6MaV
# DATA qvNUW1X/t5beiJfcGQ8VtW4mZlZBWvK0lrDVkUGD9mjs7UNcUZTQN+DvW4TT04eo3YrJYZaRBhVCv0lAw+9q+F8odx20qkoi16oh
# DATA Vq2hcj3rGv3acRcIx5w5YqxURT55oIDcTB7I9RRFX7UpQRfd7tepG/SDtHBo2NIN14bva3sS7x+K6WgfQQdIrwBqV2DyGquAEjAd
# DATA vJ81DprwAsgwdbtEw8G3aJHR1R8OO2dqMuHz1xr4mk1ZN3rHJXj65tVlzNUA/ymfO5N2I9IvXbHq2Yz6UhtBcr2bU1DY1oA/L+Fz
# DATA JQzPzDSju1gDvcQogysXV2+PFB9MFZVrkyHptZCbU8ycnS7y3fzgA62pxd8vNRrpEC3LaKmjQjWzpF5p80J8Fp16McQlc2bdKtSL
# DATA mYbBTs6P+uoM6s2H+xHGPlsq4eYulRtvms2sjd0NWjak7CvtUW+FjOErxhhevqEGXuL+66faNRNGwKrpcmQABq7hhm6WDeBhq3mm
# DATA cvGtqj5rbIzH7bNaL8N/ObI7K7+lDev8b43/Vd+qzr/kfgT1lGPdlU2qz6DcwWrzLdKIL9zjlfQ1DC3s3t/duqWDA3RlrF1XBKdc
# DATA KhuVlVoXX18ldEnkoyhgvgww71PA4TLaKSj1FbkiEtLyZ/Q0qpnCy6GSqDKI7QXJBShjCenCbAMIQSzBDjExiqf7UlPmq60aazeA
# DATA yqD/EooMqsBht8SRCVYOYAGGLx1FVyh0uKIdrJglypegQiGD25ASBj4quix3Nt7ZbG3dhf+G/BSl4WbRv7bfBcG+PT67rUM9SgTW
# DATA AIkUdc4v3BE45CqJ4MfDviLQDji4DjmiV2UOZdYqMYiSsh1mxoxUoIjdnEbug4Zkn0hHGrl/sZSjRo2x7CVeCSdFymUY9wDbH21h
# DATA kcrzZRES/30um/8UrD8V5LptlrtY3hDcXDZXXxNRbrpHmOoUItSqjKGMbtKDR2WzMw+gyqZG3ILi8F9klTy8jcCTHlsGx8UBshFi
# DATA JEqgUQs7LpmBWGmlvFjnGai5WiUMump1pKQPFHW6jFEncaioF/ngoHlzgM/VguIGS+0k8JGLzoX2FTeu4NJpXOSP3DN/+s7heUcW
# DATA dv3GrVube3utt9WJBfaW8pehnE5kB/SEFgEE0wzkER9uUZGsXbpr1feKHnc7oGN/hJnUeU5I+3gjyU7aY/L+SCjXgqJAZyI/JFA/
# DATA 4YhO2WZAgliyWeTi0DycncmF4mFnd8V8xw5/WhcjSyPnXhXAAc+WdNoEqMt2CkgOpszJSjoiirohgUjxWx43wQFpvIZoRcPJCSBL
# DATA 59TjJo9hWb6S4Ec2P4WcmBrUBMDeWsh/ySQc1HPlgEhgLxijiiA3zlNcKjUZ57PZkklyDgOqewn+DlIhCKPAcL68rEmxjqOXsjLn
# DATA dNNZMcynoGlYXqblm0WEZTF12jfYrZggJs5TdJhSXdcbOoWxq9/wz6ySBNumwnvGXpW+3KieyV7z+xZlX5p/BNV9qfUQdyEk9/69
# DATA vfs7oB4wsmaoCYKUIxJ0Sb8l0m8+wni3mLKnYjFt9adyW4QBU5RXBK4G4p5ppKDVQU2hPv6IE2kvcABWdLQ80CGpZzKXkmhRvzyA
# DATA MC7dsr2s6LnTgZcaHv1ZcLpvbd97+87Wrf3INMvZxUi1c3W3TUDR0Vd7hfLJUvN1/Y2Y9/Zk0gbqBTAK4c5AwOCUa/cyeYp50JXw
# DATA FLgj0y/Dfs6KAtFEx8CBtgQ1o6Cnvs1KB8u2TZjkcjk4zWYIGO7FpR2HEYRoIfrQdBIGIcEv4ZuK9gHkyL/6kku9zOak3C+8MwVt
# DATA UWsBqd7QXlU7vHaVLQf43UFKkQ6QFcizKBAUNnkfotKMPyCa0MzhFalP0GZFf4BnuxlUx7kFvzP/f47qfOFhQMX23/X1q29c9ey/
# DATA 61f/6P//ndl/984GR0r2HoCxEIJTyNPG9Tym1NtwhtoyQQO54FkUaeSvkOHDtBhPJsK6y084wZ82xh4fDSZ9/QPg6dQX+qeJ9n2h
# DATA NmQQ+C9jLf7h5k9AQbl3/2Zr5/5NRehbt7fvbmzdS5c29va23rl3d/PePkY+ICMCWRbG6V+W3qqTu8dB8mDSfK38VvA5vlhu1JZf
# DATA hfTT3dpdsOgd9dtZltzG40hXjb11DL62mhciiIPh+BSckZhi5dr6+PKVYjiRRrby0dfJm8nra+vkV8lOWZDM8kH24MH33nrlwZPV
# DATA 1eqDJ2vHD568cdxMmYQFVjzZ9ZQG2mLVOl+PnhmBabSwR9CT0Bgh4p5zlfIL2hIY7IPMBSCiVJKrV69EzRMXHyB8SSM0ldRID1VK
# DATA e51BOzX3SbnWh6yHbJp2pHMn4J3/LEF1TtSv3RwCPwX2R3htL9p7UAnAnsC2wOr7Olpz05pJE43jU4/gXzWwDiXlAZdISLCF+UTt
# DATA X2jw85LqgIq63y95WVPViVl9or1hX/sA/lLnJgWoovGkzKLE2PRAOGIGtSN+RtjCAdv9VEv8J1r9rq3N9JvyWwu1d4ldz6nxtK3q
# DATA oF5da+ptTHmS9ESi5Qp3v36n16WvXVVgWa6u0rLUUi1cwW8SAW3KHWf8KzzwjepfqMHWWv+92nxNPVrxn5WXadohG9LFR8oMHO4S
# DATA MooIhxvtUjOioBGHb5PZA7FxSc0i2QF1Lm2DKAKEAJ4s0mclHW28DSL7/rtp5Pi9CDcgPqMArHJvOHkbEFi8owreNTwT9ZgDq3Fy
# DATA MGP5Vv2LShd3MFpdv8qZveXbAUAkwWqshflAbamL+w6tr0cFs8XWFxOXtSdt32dIDOG1ZK0sDxsUL7vDvNze4vWE+tRh+DOPI4LD
# DATA 0Qf9IXmmuMdB+6rUTMAzENb30zneau/t6k15a3dzY3/ejq3IfOax/dV+LWd/RdzScjeb2UrfbBUDNTbykhBDc/Q+t1nhZzC21uaP
# DATA 1XDF73s3A5XoTfi2N3i4te0d0Zz+3d+5vbG/2bp5f+8njqZTf3LW6/Y7TPd4teXaaq8khOIAl6SshJux0DHJbE2RYd2moiBgatKV
# DATA IGS3LZSTWil/2u9t77fubtzbeMeojoy+sCB3riTXNjtzQLPtK4dw2xacMnHItYvsGOC/MPVuDK6RVgNxn0QZFxJrSZJHqWCCihkD
# DATA SHMda8kPGkg68GUZfq1dy2NPvLqYQYfLO8K40AWNjkprlbX168ZRyfW8wmZjDYrGeLx5XefX2Pnrl9wvOt/xuV1WnTarToxA+EKw
# DATA BQhXN1uygG9Y18wmTsYuUoIz7Kxkf5FsyuqpjH8JGHakgLAYpHNxUPFSCEwq0pJyf9CLAesUz+Gt7bs723ue2jZCWULpLpo6uhxV
# DATA 912wecsOwXIewGSBvg6vMXeK7Ev6veSbEszmjCL/Ry0vOCLc4r7NEm8cKhczKHrZ4sIc3LGM2XgODpqxphyvWa4niv3lt3Rgfrj1
# DATA wqQQCgi63wUpk2Vdkf1cwm8PCDC76al78Z2TwBufhFYeWlPdRFOfCP3AYYQo1bPihK6sX44eaAbIQjIy9eTJ5F2kLYWqDyjt02Ez
# DATA ag08ub3MAxTzmWWkmjj/qJu2ShoMjETjLnrOeErdsnOBcSX5rWjoOC54oOQ58CphKbGhqNla+WCt6Tifa2y4gzoIf+Cp+LIq93L6
# DATA sthHP5sOkTWggqsy80dHP8aBlLBkRbOspF3v9c2nUF4xtHXTBXaVhmjFVVavpJKswLsfJChWlrAmLUbCD5l/N30lLS9MWFzhUM4c
# DATA dXOtrtptRhQWuhgoo3BS1T2IurRXtPIJIxrxXWOtjJMv5lo6afG20skcSvO2ofV0wR7Y7UhnJry6mu76hntUG0IrvIdzTRIidbIW
# DATA jrRHVXCCw/6RwKJTTTqt81Vm66uRPTJAsi0m2CRTQgpj4VQfM8AW0HPhV+KaZsOWjhPQvqICGtqsR90k9DxQmQP1RdN6KskkK879
# DATA rr/ylahLF7zWeSvqxkibiHoN5pwfdlEfyDruGmcxKC/F9wVnbHW2h2iNqtPgCCZXglYwAuLEYQq6WtCYlrw2cXvUqAqiB5qiaphG
# DATA oguH6Wkvy9DfxzlM5ykOVrFwPGglqFDoonrEPTvpPtEN6EyBVL7XmelzaO0OHLZCmB4NDAFgJC2QhFjWQMHJSgtWRg2FZkdWyTnd
# DATA HFZgRDKbL4SQzRoXIBSSftIgwrMvJpBaCHQukpnDSoS5OutO+CGKSXoJ0ElqhJAnu3oNZjFtC317EJZuQnXUoQO7js3FOcZ3N+69
# DATA sxkj7PZE6capz5RlyXsW7j6H3T0ddgBXrmP5/0uT0yJSahh9h51dynOMKSCOl+RqRWf119GNNJfTvRCR9lnhIloco8dadsxhqfO7
# DATA nn9T5o+lNhqOSqp5P1Qo4Jqj3n5hfXhRaD4kt7zJLOY7IFElwXfsU4ACY2d6OsqMy1t3kIEzUTs76vVI8V3BNM+DSWNdJ9RdwG2R
# DATA G0BiDvN/mKaBg0LsIsUz8JIrSRD3Yhg9wSqz/Q8ay1nG3N3HHZSVTQ8xKAdrC9aeTr1XHLaZmpKGMfzx10tFO8nQkUsNiPsN/5gw
# DATA HHDJ5aVR/wSdiq0auHFBFeZGfokk5rBRTduM7Ox850v8uvQiF4vJfKUVijqzN+sHlQwZS4VRhYGBmRyd46+WynCbOx2helzNHT37
# DATA ZipdrpeyFoCKuLE6fANgRyhTQ0YaoRzHGpt/6rQ96B0DF8KZqayH4YHTvWiyKZ1ICB/aNNecygpT8kk9SPTe8vx4bQIrjxMTFZUl
# DATA y7RQI7OAYcfeVsw11x1MTxHstKQ3jZ26ppc5a4Iu0ELxEWrXbQMle+mW4w1FWFaxfWImQFxZ2Edi3PEDehFeRDSaM585bcR3Vim+
# DATA Jxiwm2sPNApLxbXbyZz/JS+Vzpbm6i21EaOddTfxT4gDDNZQ744xuKFnim/mOi+6VITKJChXPY9X8Ga++KJHW+50QKr+pYtf7LG5
# DATA XXhxrHFVEFUjBiw78sJ/NaTvBfz/TnsPGd/vhboAFvv/XVlbu3LNx39ZW1/9o//fd/G/V15amWbjlcPeYAWCJkZnk5Ph4ApEiW2P
# DATA IPN6Mh2pPdHpQuhoe2DhMgNcUgc6ErA4Pa9Adqdrjx+iv92S8QocnZE3Hmgy4ORqTzz9mwJ5/wqkwW/sBhjAx0AmAo0kA15+8/0C
# DATA pRfh0qUTTkWhaDpdmlJ1o9kYf6J0/fahInshEsItBkC2qrQ7WNKJ+ZJWW6rIWI1rFLCkpUKdfqUGXtlqIVvqUwJa0IBl8HbhasSn
# DATA Vhae86kOlbCfBrZkqYPm+H4xxAYE/TtgJCftMeKRrBs8EnwiIUnUA7gTbZoxLdLqIbsSbr49wKA3yMw2TlIbHo5v252PR8Ftl/Mb
# DATA 1wanBReZJFKyOjGcBtstKu7UG5swG4DUL5pMbcKm5wWzou0+R0KZ1hBqNe5SwyTn4sE2+N9KLObOGOcbrI7DYKr76mQ24BRKCaas
# DATA cXJ0OE2731NsUmYPmh90lnFEJQZeXhoshR6bWFodTvGNjrPWwmLiINRVa/9RSiKkox2srLNc0qNhxBAavDZ2QiyUV+L2vT0AWRFF
# DATA QjycIiyWyvyRvctOsZwt0ELJXoA+0FdNI/1r1TKlUiOndccp2pFqXoQLci7oybkHejL7bkFPFnAkpGcl2/WK66zMm6piXaXBJHj1
# DATA 6hVvwA3rd41TdX21nG89MZmIcqgFrR/lqZsMKbNwCf8rthQozB6pGQBC7Z7WCodxF+PmVKLvsRXqOYc7NNyN5B6RWMAnbkpDOnXQ
# DATA RI6l2hqHOOKikZw77anOYXQanWsOdtNhthx8oFp8e3f73n5r895t/YxNvI+wn5CWfeb3aMBNBn0yNjJg6VoiShDtD5cng0te0GHW
# DATA 5fm+BEUFtHnFmWFQfsnpJzXzSnIbSYbGRMvY96t9NB5mWYIZCkywtwlhmwwR8PwIfSsx9yJX9lOA4YdX+hOOtSUMAvWcgmAOu8D4
# DATA ki9nh/DR26eHvYfT4TTjuFyOos3Ykxm+0hpKORkQII8vsLx41uD9SAHvceGYIflLIha/JOq58Jrl/Q/7h7vpgJwY/IuV44z1pUo2
# DATA E9upyLrFrCwm8NgeeL2XzewWHKzjOCqB63ptRsE01B8JU594TGig/ranTC2XQb4yjQDpAtCsR/nYXVHSbQ6mM0b2LNVw6llAKTNB
# DATA Khtkkya8/xakAXD87tVpmfYnVgmYdQlYUXXTGqkteh2Z0bgVmSAPcEEXYGy2MIOgw3X+GYJpm6qGjwdo8MMqa2MuVCeXmtUm5XE8
# DATA ORrXesOV/nACftQrNlw4gINxnFzEJNBWhrbmrOy4qxiQHstRbqdWqFPVNeP5U3fHgpo087lhEcJOOiHP4evZ/N0HlS9+f6LbmP3h
# DATA 65ntEs/d95PuKTioxWRYL4K8FIAPaDwCLTeaByZwngLJoY3QOKzfwEJCCzy9sIF9N0NQnXY6eCl6pww2v1arQm2OxwN7Y1ApjGZu
# DATA 9BX96bSx4boeUUH3y8YLnKBCINhYsd2QxxK5kYbA3VA//TOpHpUOlsVHTTKENSh2/Kg9gixireF0MprqhxPCnWqsXV81RJPHScMC
# DATA RaidIJE6lGP8if11ZApoWtjaYA/rHExJOkIpkjEy4c8p8r8MhJJNhvQT4VA0GApCvMzA7sLQKcLblBLPoO8X9pqyL2K8kwDi6bYz
# DATA Au4vuQmPUsjvNj06SYTEAAkfn3/47FPASUqeff384+cfYZZISCr56fNPIOdj8uxTnTEy9aDmwYX+/YEiFclxv40jZgSnjzBTL3Md
# DATA /LGGfkJgps+w2X979gXAN1ErXqLJsC3IFALuN0OAPRn0uh1sUMBDJc9+q77/A6av/J8AYh7Wcas9YIhRADHSPA53tNPunqJ5LOUH
# DATA CGcl8ac+j9XJNKLNrk5C1YPf/w5TG3+IiTU/BrQrNTPxfJ7qRWSiy97Kmt2IdlnYjJShkPY/GTJoB6htSa+MONwb6E2kH8FGYzgu
# DATA Cb6lJ+CLvK7+MpFb59nT1M8BqgWKMIts6Th99o+U4VlNx2fPnurWSufmyM3KvF1+iwhf0LG/xUzQTwEYv0K9+iw5D47vrA4PYfyz
# DATA WiLTTOuM85+qfz7FjwEZDBKaPv/Ydca1h0sRC0ul0EkECE6JMHpQxSJds4JYkBBSxnPWigWFgKE31OBhfbZce3B04kqMPNuwuiWY
# DATA 3qeYFRYyZ//rfHS0nI3uqNAOfH+ZkdMlHffsUkfSg2HQGs6FG0BSbspZMEW1Dk2HNsKLUtkx1QXqNXf4/8tJa/vvhgJ9o4ng3WEg
# DATA rSqJHg6jWdG5r7IKJ6r39G5Fj5SISuymIQW61cOq6w6ycON0INCTng6CuByjK+tBWj3mL+FdudnUWCFsvaA4pRZZAxkaC5WF/IgM
# DATA vC3yQjRZrjnXaex+Vo31u91Rg5C54U+LYiUPiTU8xLIsQCSd/bWUC1Rte88HiXgtDlOSld/VFjwbrxSGaMEJCw4rck9c1qyYLWke
# DATA 1R2Oz9/jhcFTmDqlERKX8lJekI3LLdGGYQi0dJm2pGY+qtXBsIqqgRGmKzDPACIM6RDmc6XHx+CaiHcWe4jACgPb5RsrPDZuyfPN
# DATA c1yzvdAblHVyz+zfq5P6Gz6cdEm6pzWS0GQRhmVJYuIjFbXbvFyjXAdwm7po+PMg5h2vWLDY1Tpqx8Mf7NVW9lXmEQA1/rPpFD3g
# DATA TPJNLVI5b9HVLz2c9vrA/Fh3P/v1BeHAXA2eDwg2H6LNNkxaat2mV3HfUdpDzb1hzYh1WoVdhWxjqv6IFDhbcty3cCEFjSqHnlsI
# DATA bwm6aW02xcyD2nJam06OcMmP4Ukp/d5Pvnf6vc7+99793t3v7f0F+bZFvb4O6tdZ0XQB1yxEfEi0Rxg4ZFEUKp41mkd2qaDZIwZD
# DATA BLFG56SSOND6dX0IISpZBnPWE7PVZkuhRwh2rmJ6UF4qciSjftPW185ki32pzRXut/SL6Z3W2jgzZZ6K2XLbEMnz5OF73M5aY4Ln
# DATA VBVaFZjG9RS5Eoxg3sJQBY/IkhRXrbZJQKtWfzbtYfpcM9+aWPpBTbJeS/hsByKE3UHMtJKjrEkQZ6lRccfrIIzmwpZyQAZbJwaP
# DATA CETM+pSLJBK2/8aNvVMRKQ8ELqxmcoNTyuZ+iW/JWoNW3XNelp2RkLMhVqbsjoeWmeMXmbNhXDcqW22e9SSCDxszgQhWX9dYXwrT
# DATA y9Uc9OHIoEhZacCHeeKEBqSer0uxNzkZQmhq63P9RsV4vYNrKomAhAR7eQ6rHOiKchjhiJbM8rk2C2dzLmOkD7CemmAeYAS9SYs7
# DATA rUmk2Dc0RSFrXI6trMTn8+YNLQeq1KMoH1hxuV7sRjmQokxFryR7k+FohDBkDzXUa0aPaslGoqkDZqrqZarPnL4VTTdK2E0QFVb7
# DATA K6kZfII21ts3a8HaUqeNSgsZy05Xk0r1QzMpEZzfZbUzqh2K0JVUCxWZB/Q5urSAhBRSWanmFJ+Hjp0tVIZAVE3p2mo5HhEdIftm
# DATA aJck/E4TL5TW+3cKzdh5GN900m33MTy6+Bp4F4vJJ1BkmsX9hRe7UshSxx0AfSjRrZSenPkK+7z68+wj6BFNNhUAZMunywFFthws
# DATA 1oFUdb7XLEsn/2RUlyBnsPIS0etBi/AVaM9IvfQ1CzG/Rd3ZQgkb5+gk0rgx8FAd3fdjy6TXvqHO5kDPOka8Fa6fXnnSYXeUYETa
# DATA aEWHOnmL5k3Sr+fKaxb8//nfgjIvkarHZ797/kny7F9BqMNHDPYfnQHUMJTWF4Ezj+iGPka17O+ffQ3qQNDMfgk62a9RH/0ZD+BX
# DATA F1qZHNF/AfIdv4Nb/fYZpMgg7ceLV1ow5Vhe1sy7vaLf5siQ2JBmLscUsg5SrYR/O44vOY74ugrGejXXLl2yi1+pFvbWjYrx+Pn/
# DATA wBuL3OlJEweyW8lgWo0zTM2jvYFrG+OHUyBnO/impK2IauyNVktdG61WWXwJNrxWmz8ppUaNTjj6oG9owDbJjoaMtJ8pdkWbpFAh
# DATA qPkIUit2+x1SI1JcFLFPbPeEX2RWIyMWq5YITAbtXdqQjSQ2NRFEVZAB4KdOuoKmXWSb0ACGGU6m475UqUWHV0XJHHtZMAnVKsal
# DATA QHjd2ajbMBm50GLX0N/gP/BVZsU2+FUT1j9FSc3c5fHM9A1OS0X6HzgUAAuRV5W6zT3uDl8K87LrmIA7Wssp8T7ymgo+nJbep0P4
# DATA KS2Xw0vhc5wzE4HI2vhVcHAVr3+Avq9cve+eEVycvgWMLsqv0AKkyP6F6GxUG0wDstTGFMxVBQNnRL0/sMNqFi0tZzeUNM25bbRe
# DATA XRamqkmgw79ZksO/HQ07PjGyBP4yunajRbe7p6VOCdjP1aK10LDQauEOaLWAqLRaacS3k8hNrhuiSX3xw+7Z/MQXoKfvevCqY/Dj
# DATA SZ/9C17ln9PtvaDFxTHzgeH2RhKxSbJOt0KWR04ChHmr4Ub/+vmvoBGojCyWcMn/O9QO7dcStROfcm8g8xA2/Sl++xGaypCHUzwB
# DATA snSVRH32EWUyAmX034ik3NizL2DvorEI2wSIV5A2GxD/QFZ5sRXPKOdQae3/jAip/7P/56j8UY5+4fDvc+K/3li7uv6Gj/++fuX1
# DATA P8Z//cfGf+1amHdM1NEdEwIHafeD+K/shro7FS0/7E0gFZd2cmBmNFssBixEjdfZE1vsnxBHir98RBhmX/xPHx92ITMy9jEe12mx
# DATA +K3qzSR2qwjnPcnUMQPfA4iK3uSMTLZ1B+TZjWovpQ9W09pPh+AyD/HSIFm9r73YyYdd6jlT4UKkLa3lssUyciLjD+rrV5sGSfpo
# DATA OAbMVAv8g2Hn1oeVErkJAASDqBrYl7JU88P0USHkqMwBw0gGu5vvbO3t7/4kdRGdJJYT1fuwPzwspcsazdXxRdY+IJGGL9K48BFw
# DATA OEc3XFy3B+klUc0UWeBFEuW+A+3f2t69HaZghpoKwWfNmoWul+QgH1k6AYa7ZMYBj6zzjHarN88jExrlrUUMSIiyK/fMDmnndEPz
# DATA YXaDkUZziJPz7+P2o241agElgA4oCND6fMSiHbyvCBJkBmqiZRsOfHtACF0gW80WGaOVIL7RQItlE84GMej9DEGjBLor7mBw/YfK
# DATA hOiBRWWmInfjkuHEwa2kT+LAlXJP729vA2DlT3BT77mOUFSHjtRl+dhFHcNLs92pole5daoeHifkNUqGiFM0VjC91oEnSgLtPmkf
# DATA 6R2r09SR+ONBgBcdBLPpW547GZIj+TxG2ziwcCbazj8lLjyoKB3ZHbb5uaDVed1xpDtNG9iKAGdJVO+cqKBZ6URQEQcuLc8C+oUf
# DATA R+MxhBWi18mEOcWxcuSYVHTEQ9kNSRionZxRso1rOoA5krm+XT2GMOHztfXKtauzNO6KCDUtSsJvbd/b39i6t7kLKJ2b9/a33YvE
# DATA bOSLWHWWoQPktK+mhxSHVuOg5mP4mNDc7AKs5FA8DP/sDVcKC8YU9iY6ZE4TFwkimYVxsMhvILFyqJaIsMgxu9jb8QLhMZFAGPDL
# DATA pwkVOh0dOSA2qlWQiaVYKKonCggkqqxBNju1GcJIpANTXVNGbXqWjIiGRitmygtAO8t55x6F9xE5k5kQ8TSGHxcdI7st5vg4L8UA
# DATA bNCnhN0S4B9m7LNZFErQHtqIDSJuipJJUrxo5AhydZg1pRh/h5PhqcvG5J2JjlLjjx6QBWQZ2+Gh5sQnRt2qaaZyxhEkD821qAZX
# DATA mwFxwMw6AF2SFQ09l71GHteDKvPaHmY1nf00HUitdAg6iJlYmPNuT0rlInTERZOklGJZUmR0Kc0MedvD46D82urqarlcDJhYPEHb
# DATA 76krJJ4dOebvu0A24vKCsO5E7A5cPrDpOBdyYK5iCNAFbOZzGVTF0tz0yAvpi2M8DGPeotGC2cYKA+cg8W5ZntIJywzB50dBMvUc
# DATA BmEduQMoXijAOpKcTQDG8qOUsfFqwvqWZNydNp9g7LE3lnoQIOixzsV1zs0QDxjzJP1u7m7eTvMhVhZBWPGD9haZtb3N3R9t3dKJ
# DATA 6V9BkpwligYiv16lIFbNsnPyX3DZU1OQHI6HjzO8dUfTSVZbCi6Eg4gP2HLslmgGmS9iV8P8JFqX0D34xDHnuPNJgAca3p+xpFqU
# DATA DZaPRAgKkxdvZINEanYkC4Lw2OQAB3yesKd82ejfFF0mDwDDGi6FlDovBEpMcsNLb+M7KUB8P/1oSumV+4oZqIp25Mbdm1vv3N++
# DATA v0dLsr+x+87mfnqxdAZi7Danwar22Q9olwcLjhjfVIXOZhw6OxoVhmV/+RFyuzOj3JsCezAc640xmJ4eGjwsFLWRjiQcw83h4tD6
# DATA DRMBpcHLRt0xhHxkGP6IwdF4KNEfEPwrjLwNylFMDGYs2dgDbpvncr68FxPzvmUR7zLinSPCvAjZThyrQCASjTGRX8i1DmZIxo/L
# DATA DImTo5EoBat2CKk9Bg8twtCOWr60TNgZmG8WoJKpEHSK/8wY5ciRKDABtikAamvb6QIcDWhRopUwEGpTY5P0jo+76CS5tWNrPwXX
# DATA VcAVSdrYz1pyD28IJc3APm4PhGUF0pl0AVkhSiQg3V7++baSXnC85wbwC51ufgPzJK0RwUO4rBpTEb4jPaZDvERjVMOUDFkHW0z2
# DATA UHyaS8O4gnNjnmFkLWOb8Q6frTVwGkN8/tCFT9AUR/iZGzurT395vrA4WyhhPTLqJtXT3a29uxv7t6Rs80qyr+ikWRA4YKSd1HRV
# DATA Lx/cV4+6SHrH2UlvBOA6A4rMTMjopGadoDICljh2W8hZjd4ZtkDs5lgwLDnUJ0aS0YFHShs8o1uTIe4WsRXm5d4NDsUlQFGWciBH
# DATA jDKItT81Xx1k8tTFs+fl5d5rkIJZPBmOPSHL9OWlCyKv+FV5fLYFL8vHQ8kxiZTLRbQuyogywdS7uwyJkC5hFqCdF0EHnIfhxw/d
# DATA iMAQhF0CYNIOpsfSz5YelegfSuRCvZJpnVzvrkUMoRBdiHQaIK7JTCmNKt+A3bOj0Gye1uALm6O8ozQnEq5lUcCCL8f5gWqMiUGt
# DATA FBzb42QR3szHal2QG3PNS5eIl6B4OJrGPolS0hrl4zlp03h4uYZCTyCkBxlVNDcLz4MjFDrsk0FQ2OyE0JXTB/ok1rBlw7RWp4JG
# DATA zYgRct6Vr81bQkseZn80QS3OZnWRhbieaJic4HCDj6Ym3+i8GBUvmys/BtWWTtLkjp7vnGiP5t88cxVhC6m/7CgrpkPpdNB+1O71
# DATA 24cUrpYuxUGYXow4WclTaKbUL8zzQB1M2c1dPTocDvvSsG5EkoL6yA+8TuM8qCsBr+kZ3rFW2037qqhaq7jM3fazCJ6LSLZ+xsF1
# DATA Bg9qXUeHQdgLpwfCK+J0qOjdcNA7wgRiXJ6ii08AeyMo9ANTRSzeN35cLnxUXAcFVzr0XBJ2uxiWYN+HB6ZsuY2xLQ0byY0BCr4v
# DATA OJlQmxf3FUXxyxmSU0/YD/fcF3TDjYEqIscWtkQHFRWqVzdug8ZAa7DxVnUU2MYx3+qsra++Ze4wYkQigXXFI03N+kMlTi+ur97e
# DATA 2dzd2N/avueqrRfTs9u4GafHurc5PSLX7yLOBOJnXObE40iaboMYzkDt6RgbbBQrgLSb8Nfa6qqJ3Tka9ofjSLXlcnkpsuWK+mp6
# DATA wWE/Jk4o0ke9YFrnUw5ZrXA2X2rwiktGS1MlvauMt4i8pYWqb6IkFtL0gQZPr67BYUGL1gR8aAAIojdR5VgdCEG9ANjXHYHGB5Os
# DATA aGXfPP7gPy1cjYtSY+FWYgA00qgSEbl04bl2FjZzgLZgb+veOxppBjX3Rt8ntyKru7bRARMsV512H4xEzH5CtggEv8B1Yn+crJZo
# DATA re7kpD0RegVYeq4R3VthF5BK4iGowlDPMHk8rOoNYZNPaFtLW+P24paoMQRHp3OGqFK5ugKQlW7pYsSqqF61KFi8AXgd6l2q+VVa
# DATA AWdI5IPnJo+PsQB03XRNMr4M6fm5N60V3aLrSQDfmsFE/CCdd1YVQMfGY5ukSK2zRRokJCOEKtEwOX8woNOMiYR4TgJ5sn5ldW31
# DATA wWAmE6SdDpVQKpJwZwc8LMqLmD5S2//UmTs8kKC4ZyxlYQ99pNNkops6VQAxcHwjgo41zcVK5vIczodfELwCT5hbK253rnelOzla
# DATA wXIrdoOQig62Aw2xLNFsza6xf4PpnoblLqFFakIvaEW7GjpjETSu18WSW1OjXvIXssnqIqc0nnTNnHMBG0MIdoy2Rb/XhEG3R/mq
# DATA aZt1oYasRZnZZmUP0Ju/dIQZnW+zYrWfegCRRGM5FOzdjb3W7c2dzXu3N+/ta3qmtTkLoFvlJdOjNHrC3bEaB2aKJ9S7AKySkVUv
# DATA gJjkIyM1rXutTmDKE14X2t9NvkYBznza7nOcMV3ngLKhqPdQyZxKgLvB0C36lkzUDKk1F3U5YKMJcxDJKYCqk3IlAzFAEfL2IBGT
# DATA iPewVRobOgG9bqIEeGzCzg8EZLJcB5h1qKaZW41maKCWdDBMLw4GZQMkiz9bvPx85KjcL13sKDd4ne7dXF/ixdSAl3BKJuTzdr9F
# DATA HfBdiUW3ymTBMb+Nx5YH+WxqNBECOb7J1i+5qDorr57DrqhLp2I+Z9abGErMyrHzQweLshp3HASu/3iwoNwtsjB4kEgWCWkPvKis
# DATA kogDjYdHewhDOaejYCtrBCLMb5KaZGPdFgcO+xgIZh0McD6FLXfak26wCaPdCUJpPLproSO41sAYFyx6VIsdTj/Lx8vBVXjBeghp
# DATA G8UH9HUPK+Sbe4EdL5HhI7u/vJDhcXfz7raS3VGrcGv73ttbu3c3vagh93C7terz7t7R7hdlPwlvlA+qR7x2MbFGEOLTdI6y4V+1
# DATA bZMzchTGzvg9Mh8j+60N4fopp/l42M3pIxnXF2xKdM6ShnI+lIoor0lOuRAD1pu+ABEm52hEnXxNghuHaQH4DU+eShVfPG6bB+Vc
# DATA h2CuMbKVwr5Doh3gJXBjyx0uXoNBKGRym9FZB71H0WaO5SrVV1Ul8fayZ8Ozd2RFUCUZcUNRXn42Y0aYmTkG7AhCDaBTEQGNU/N5
# DATA yDXRs1ycdDd/Kuacb5+/uEArzjx69fhQSzmsSaQJUSqaxtYKM27YBcNVBQYvuSj2gwUSGDM0JlodPBt1vs9VOSfJ+xzF1sVBhgod
# DATA zSUAUTH4EMykDzgkE3fYXW8sIqBL7CzodKqvfkEp6wFCuSGM9cTkL5QxnXlRRJYjXpAbd72mfL7cbNFvGLqsWKtHPcpaFWHVy247
# DATA rGiSyHw89aYaoIj8dyw00MTqOmWk0sLy69I1lICtJRRe3lpWmFJbhfJOO8vYcVRvCMY1QIHnSP2GmVa/UZ+D0AdH2jiQqWWwib+M
# DATA OrnAP1kvT75HzkJ+GeWLLqzvmq2BwdnmKhd6wVOhkXMT6cqsug2QhDYaW9eLjmODR3afOFcMv3HmAZ5RVAwEp2S9v+ombybXXn/9
# DATA yrWLeKNv3vuR4IWsUyp4cvRAEd0vjdO/jGAlNkoiNKDafO1Brfh3+VXChi3S1wFMW+1uEOppHDYbjsOmXCbPQdO9vAjcnfa1hi6/
# DATA dX9vv7V3/+berd2tHTCKqaN9f2+TxwbqEKpaEY4HA2PR01hO0lTGME5hKgS6mS3ahJPs4L+4QWUBJSBNeBzgPmoBKbKGxxGo/RkO
# DATA Q2GoE3HofPs+DzzfBfKy0NR61/ntR4oWwmDTqtvCPO5yPgj0hVxUkEzwCMmRjh5X/KGYbgoUad5Pl8Hdzqu9LJe5xQcG3BsWHFXU
# DATA OXA4fghodwPrM0/AajWBJShvfSeV9IPOa6W36g9q6t/y+XrlCvqouf2jW3eB73R5h3BPpiNFzE/boxLOh1e3dkitAYiLot5e6Vip
# DATA hZQHt7ffu/fO7sbtzdbNO9u3fmgUBy4QPHG7PPNoU1kMxncRHf9/Ir2+mwkhtN/4en+fNs2+DU335TXXF9aRF2m6vyXM91dgS1LC
# DATA hqyrVlH90T+7gYygCDHQHvJZF2I26e2w34f2EjIy1pb+y+uBY1ruF2dfePEWg0taLF6MfcFR/79wfXjIoS0vl85TXz2uYX/yGAw3
# DATA 6ydYZeep0hcH/L+80v0SCsVCFfm3DoUc9Yaah90vvaEupri+uEL8m+hpF9ZWhsDkBXq30Jc61Bw6inL3XZHmnSs3GnWRtHqRz/Os
# DATA BBea8BzbggDA+gZa88vpjzXYOrfiZYUphC5/EYrhy8Ka/1GpXKBU/q4x33MJnYR8P+JcqK5qwROkbNCP3hWPmM0iDZ/MQRfTVLDf
# DATA tTYL++qJkt9c2QYeCX/TmNIwlPgwCtwoR8gXrkHW6OGTs0aqEQ3S+ZAFC+IUcEB6LBh96UXJ5AtNfSx3q4sfsUC44UKpXXOkv63d
# DATA zVsQuo7G4827O/s/sQFUPR0XfAElpqOONaybjiUXg1F8PcLmWE01t/MN+oxKUvDWM87xZusY57vFfOB3t38sKqUtKeJadZBiPGLQ
# DATA 7UvDurPqkfr15Yrmdze2QNn43+5vOSgsFwHFI8Vcrz8hYQhzKDZUBTVGgNPSJa8iqjP1iuoAP1SliyUiDUBE1CIHU+xOP3vRvShc
# DATA OR12rVbuz9XuaG3+eGtvfy8NjqKTHy1ftcVp0qReq3fsDD/c5dLVb8M604+7TBOT9vjopPeoy+Ir18UJiwdH3Rs6h5cI633l/2/v
# DATA W5/buK4897P+irY8rgZEAAQpSnLgYBSKhGWOKZJLUnY8IIICgSaJCAQwaEASTXErjpPdSSWVqUntp63apGZ3az87Tuz4kXj/Beo/
# DATA 2nse99m3GyD12GyGSCwC/bjPc8899zx+J5j0MWI60jV2Aeey1WcH7Ah0swR1uT+CZa+9+7i+NL2LatgFfSuNomdSxCTYQnZ0tHMF
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
# DATA V5+rj/n5v8tEL98A2A4A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
