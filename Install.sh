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
HELPER_BUNDLE_SHA256='366cacee36e390402734a07b993ae3b660ddc4568ab8c84d7cad49a78ba611d4'
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
# DATA H4sIAAAAAAAC/+y9a3MjyXUgqs/1K2oohQHMgGi8QbJFjTls9gwtNtkm2TMac2huoapAlhpAwVUA2VSbEba1e++N8Mb1L9j7iPsH
# DATA ZK91rfVa0l/o/kd7XvkqFEj2yBrHrtW2hgAqK/PkyZPnnScP9nf3Dk/2vvf7/NeEf/1ul/7CP/dvq9lutfvqN/m9P+h1v+c3v/cd
# DATA /Fvk8yCDIb/37/Pf54ev/J3nz/eOj/zP9w73jncO/JevPjvY3/UPmDK8L+MsT9Kp36n7m/6fBNNFkN367Wa753m76ew2Sy6v5n51
# DATA t0a/+cfxZBrcBNex/8Or+XyWbz15cpnMrxbDRphOnmTq6Y+8ves4u02nsZ/k/izOJsl8Hkf+PPVD6NQPppEfJfk8S4aLeexD22Ew
# DATA Tyb4MIlzLx358yt4cZyE8TSP/SgNF5N4Oq/70NwPr4LpZTK99JM59j5N534wHqc3cdTwPF/+vcziYDIcx553ehX7hIbRKM5S//N4
# DATA GmfB2H+5GEL3/oEMAR0F/iiL4zpBOI5Hcz38KM28PB3Nb4IsJtDT+VWc+a+TaZT7AOtNmr3O634+i8NklIQAzK0fxXlyOeUpQyeL
# DATA LPbCNAVMwDwB2zeANJhjDINNJotpMr/1kyn/EMCI0Ok0nmO/fh5ngB5fjd/gCQloOcLmT9J87pcAOMuCcI7wMIQ+PlVweQDXPHgN
# DATA zW+CW/82XWQ0+yidIMT5leqJkB0TZNRJw/c/uwWop/MsyOd1D18sRymPl0zn8TRiPFwCbQXwPS6O5y2NBzhEqkDKJBQHMJn0Mgsm
# DATA 6+vQ0QQBR5wiCQDRBQm0wu7MMiFesJNknvsLwGEOiPvqKgbMx7hQwWvsFV/RiKvjI3w1i4FQMiQwGEqArCOZebMMpgYYOHpg0vbi
# DATA G1jnV8EcZ+5d4f5BjFoYt3YDb4Il+Pyq4Ce7ZJKEHiZ+MsIugZ7yq1pdDwFzCOPkGl9eZCF2GQFRZUBcU/8yntPOoRe9G1gQ+Gq9
# DATA im2sVdfDw+uASB9gCxk67GQKdHrjEZyyQLAREE7d3etpeqP7jVLsM8eeAb+4Js/i63iM+yLnV3CI+2gKRpnH4ZwpiJhT7vFmugGy
# DATA ncfAkvxqq+YHOSz6nPYys7B06kyHoay2azATWG4PISSeoxjCzVUSXvmXgMScwB/HlwAOsbKcGKbwsrq1dB70+YQ2ZJSMbp3xYKo7
# DATA sJdh40TIYIcwvREgENAYAblNIyQ3pFei1YqmjITR4iUTmPh1jEwwB5KKcGNB+3mcTQNmoHqr4KiyFnVcZfh+6yl6uEmANmfAGyMc
# DATA CfgpQDQBsr8OknEA7JL2DXOPyFqZ1EumYZrNUmBfuAFeBNNbu8ESreL/ruIgg80P2wDQ4sXQwSILLuHrkFGTxfliPMeJW5wROv8C
# DATA WDlMqF7giGZvA+QRrqfLIvM6LyB3C0i69UcwK14nnOMwXcwbWhyskAMsqxDHr2lJeC0TGFBwTJMZx3MCnHDNHQQhbIscNwW2UWwb
# DATA SROG9XFCANk4DnKWXLlnb815anXV+ACZpTmNI3xgvVjmEPEQIvMFUDNiktAUm2nZYDA15IYcPAFMSylYnn1kuX+xSADP9IyXDskG
# DATA 2XRBbAEkSLhJpJiJxY5GLiAKv9liOhXcZgozHm0LfgWYBHcOsJxiGyBZoGRZhgVLz+V1q8O6eIE0AxzxeiVI89xdXTb78poKEhh4
# DATA 7z7gcZdP/XQcwdRFRIM+AWuCsgDa37+eSFk0cn7Fu4Sbg2AKckemAFzpZIbt/DyZwFJl/mUajHPCCFBFksNMATJ4GxiGgYRUJY1o
# DATA mYOC6eUBq1fy/SrIPSZY3MDI5le/KMxS7R14jUbEVVyA8EdRZbQ5IW9gQmGCkgBeyln0A29M5sTGkAshc4UeLP6qdh9jPWRNapSi
# DATA 7oed7h2/OPF3Dp/5u0eHz/ZP948OTzyv2fCfAaedcsfQbO3U4vJrLOxpidXsOmp+D25A7E3ryGvAjnMQ93EA8Guxsz5OQPyPgxsR
# DATA b8FsRvuzoEJ6SoXEXQqLnceTBNGxCHFjTYL8tYAeg2JLrN2GHJmxHpG4OG1BwXfEa0DM0VOQ+/5eAENJE1Z/owi2NK127q+ByFuD
# DATA VmvyQpyvEerXcNVABQAxtEYsdoiSKEpghy9g/qgkpNllME1+FiiEn6b+GgtE6IIhYyQpY2CUgaBDdS0KZqTK45cZyA61EPiOh/IO
# DATA GHp+RTyCGBCLDiXgjWiuC3YB4yxBhJkjX5h68RvQiuk9ZiCWHCLgABWyYwMB3NrgawKTB7JtnCCDx1cQeP60NgxYOK3RwHYr0gDW
# DATA QpDiGbTAX9YEEXEi4IJom+oRZaGtzqlvTxQZeSwIBiY7Cy5BOC/jOCICIYWLzQ4QUSwWRDh5NuZu0sU4YqUVtZ4I2Hw4B5IFKJT2
# DATA ksDXcaK0BViYEa4E6SZCakjlsD+xhVkf2AR1P34TxrDI8Zs4XMzFhsNd7SFDAw0KyUfUJxa/oHJfB6wU43q9lHkiEYBKMl4AW9Sc
# DATA wnM4RZUmmxoZbLMN0JWVhNeqj4ga5v2sH6LgRN0BVBcweEgrp6VCu+oaWArKyhzshvFY1gEwdB0XCR33J+50pJ2ZNQHiCPEUB5eO
# DATA PSR77FUZDmmmVXk2C1D5isWuIvNOGZMBqY7QZ5YuLq+A/2uMikjm9QYZ4IPpNs1HsUhsVmLFkGb4AS8syfQo1zF3Tz+MApDhgOvZ
# DATA OLgFVrEzw0llCS7TAWnJhymYncAylPoQv5kjcdB8yWqQhQt4vCnyE8I3dDRJpvANSOw6IensjeJgrs0nVO31yLC7A2tsQ2pTGl+r
# DATA +N4cFogFu+AomIt6QdMG+ZqhYXpLckdxHL8qxCp0YU9CXkjE3hMVJ1IWmGKrObFIxin1Qf0adqwECUN6BYYSyqEERC0vi68cIYZt
# DATA 74/Q7rPWAeRoTlZBAMPmxDNpkqiyBSRdYJ1nxIyNfAk82K2LOpvVjHFYGDQnmblQT5M4nuc8fpjB04wVnFbDP2E1bhc0IZHma5Zm
# DATA t8bGt8OGWOCjXQ2cDR5PHN5OTgzejvYmpW2QzFEMHQ1/GhPXxu7Nrpqm03VRy1SngcVsT+YBMqzI31foMi9bKOR9yEw4oWdgEyZh
# DATA Eoy9XPUQoRLBWlmAWzK9BBmH6rM0yP1hGsE+SpftFj1QrrR0xgFiH7d7uEAFTky2CSJhDNb3Akwl1FljMQBzst1gX5D1E0xSaGdZ
# DATA YDhp4qfCVlQXan1ObnNc34NkmAXIyNZYGgonNkqD7E0tMkSWelqWUiskIVD60nEsFF8Naog6eTtSKJjCogA/kLUB7ha+Di6Zsb8I
# DATA fgoo2AUmlU61a4/1SOFFRgWAAai5ZzWnvT2ssfIOVD5lvYrZqTIDNMDibwNELo2LWx7IDPRpFmGBv0w2tFwMHGgQuq3IoXxJiCgD
# DATA guSHMXkQD0DNO95aAYo1IRrcaikM+gbgEkKFjYFNUTMDhgPIDNVLXvU1mP/xGBn7NALmkdMaM2pAFQUpp3CgrEMx1nAFuLFXTZAM
# DATA bmsohXmCzLBdqgCbLK+zJoLDJ+M4Yzpk+w70VOMi5Hawh8yW5b0GDGBu3sM+cXMLfe6mwBryWcqeEGYwDiNJ3B6JpARF47FXNC6n
# DATA caycjqS6z2PEMGzW8VhIZ8RQmpkSc64RWGTWWoORQyu13To8USZ3wiZwyNmcPCXkG03H0CxFm05rCo5nYw5qWcxkrnac6raSe8XN
# DATA SijliYzXZ4tshj3P05QVbnmANq1x46AzVHnkFOUq14mlZAJWgSIQmWxyuyDjnvTMy+6mZGhhVs+RPN8EuCnqftk6elrgW+qDNsr8
# DATA UTImPSpPQ5TjEW9WWU1+KO5OQTv7F+Pi1mKvdQTCS9DGYYbbaTBhv4g3TqavkWcvhho1ShfQuv9KL744PeqeEqJD9NnPkwnqHlEw
# DATA D5SXRAxTMmGZFEZgoYKlNL+J4ykj2bNhsDz2gN3cQS9vjzKsEo07FKTVfOVJzXIPva5ZrDaBHyzmKQAs02PLa3lkZziPh7sPEneb
# DATA FjmedmLmwUTPqt3wPwty4EgvtfGBxuIOWH/s1fUvKVYQlahLRIzqsVLZ0I+AMmbJ4/tS+UIRzRSSgBlcp2yeKM2N6WmO5OdZfghs
# DATA Ponnyq+ixo/foH2ToJYagKaADgzyRy+m42SSYB+un1jxlGXrTkxQME9AV+f1UP4vtImMrUhmqXwn/6kFDsk+9vRKT+zLmpKfkQQK
# DATA Cjr4kM+TOdgErHmbzovzAzE9TW/ABL5k53fmyZqgnzdIOBCgHcW4L66DMUvl3KB0eOtaf7C8X4NJiSox2jZ1Qoto/Wy8OkDlJoYA
# DATA JiyGX1iR1nar7TACcTdGjSiQlVChO4LwBv1MEiZCPwKQDIVxFDSioBcGFx9NriksT5FgmPtiiPIquBY/5YSNNVd3BethvMhhGcZs
# DATA VwBcxMeVP5SiL8jpgB8mY+a32M74P5EZi2PIolMVpkEP4C3hwlP0nxcNBtyO2qQj1wpyqyxhnUzkAmPYE/OPGJZeN6IMkjZXC+0U
# DATA d4AsLJonU/UnixyFHK6MjQnYELRAw/gqGI/qsrvpJ/Y1JOimZW8gglKnbUxzo6kDIq6SIbkwAO20YZQhz14wDp151KOeRhyZiQPl
# DATA 5OKPTsgnz+t1lcxY8MCbDYx9K6yJSwN6Z3IPkyxcTFDvR43eCW8jhaCGLj7P2KFQYi4wb/RW+v4JKYjiJHWj2E/R00IipNX0kLAo
# DATA qgAIx8BbHmS3AF6ngRwEI2H4/isOGrHxfcxb9TmiZgfk0/ouAXyN6iP0eUAb8TB1lg1FJxDHEOUyaLaRFvOoIY1GMXsAYLiraTpO
# DATA L1F8gAUZUIjB4Mdy+8B290eLMUjvMVEMTPZS9oW0R8MHlK5WSwmdr/ZfHlkMY56B3Q99RmC8crin3fSfAQomQ3i9tbnZx93kKf83
# DATA uVgVcSgijdEdxCgKHSTAkCjF1Rx0cJg3FnEDl0PWOcoaIBpwqhINhOUi6wGIfpiA5CgO4mDMV6P5rluEQzP2q2jtMdqZjYKSmoUJ
# DATA kYow4hKhSMSLshnVVtBDi1uTBSA79fJwHCQTmgkF6OciqEh8+SZNARDsONttk4psQNbA4ed4ilyVDEZg5ahq2wot6SJ13ubETZOM
# DATA aQx2a0WQKTPT2FxaMq8cm7B23YZv9uuXKplklx1mRurIyhayTdSkRCJXckeBYYGi46cJR9MQcbBNksWknDVP8xmY9ekiH1Oui2e5
# DATA qeAXifEgTcfohZeUmHudWU+913E8w9VC7zVuVv6dGYtW+lw1CRWe6a2HXhKlkFzriEskdjoGkzKldAvjGZhABZNRdA8Agr9gCBZq
# DATA yNE3QI/yqT0lMC5p44ChZuIHK3xc0CpVnmrXz62XkVMgcBBKyECKmqbyGcWPQaq9JKg6eGoLYD8U+IfdN5ulyOwy4waUJAMOL6Fq
# DATA O4pR/+3ZZPZCaXKiA0seVQm92d77JaVUdIui20tb1Ylohc5L4l1RLi+bXhVjiD2tEKhF7ZbRqgStYgm8jCQ/wwiuLc8LaqSksj8P
# DATA xXoIiLq1XIelpEhoFiR5iXhsgA7Y/YOhxWvMPYkwo8Dzht9qDMoAM2HKMlOB94AtiZnyua3gxhsoFVisPPIECfS5ZCuYB2jkKKTi
# DATA Yq2t2BprMLGwxnomzklppcT8ga1l2qK1/GnL0TqJ8aEvENr4HKOH0YDm0zyPcxWUDUxUy3r5BmQwe7sxUM4bu27vsoLo1jzAA0QR
# DATA yoDZEjHVFT8gSG1hIMaV5FuRLVmHZbkMsmiMEXTUltG7fYXbAR3m5AiMo6LhwRH4aVqwn2y8KSvTKGQ3wS17Dy2vCqj5YJIkSFws
# DATA X60OJWWKsrDyGIBlriwsPmKnVFTz9y1hdxXk9wRDADPEc1jn5fCEtzIs8hRxIX4gR/QUR7E9x0TubAepEfyVI7Ck5WiD9hKQiUJa
# DATA M2nl5CFnZ56W7a7Ow9TBOFZ4kqhYFM8wq286V4Fr10nECT6gXU85dEOKjpOg5CgmxJXdHgCwIfnbVcRSOV1YPZhgtAOlgPab19Gw
# DATA Q5MUw8TX6XgxkTyQfJ5i1hE+c8KDSnxb4d6ptxZcXiLZYhw1UZAaFNHk57mTuaTEtEDuKfcmq1IkGDmLBABwFJ10qf+KpCp6wxg2
# DATA O6JEfFMmwi7GKZscGA6akmlVtnwUMYf/VzMyHscwWHAKntl4yGFsiW+ikUa+q46Acvq2JDwE9UKE4HNYmlIJ6LoySly5Wm4xq/GM
# DATA 3MqBxyLieyvFlxVgm8A2BLpZxww34mal/qrCYEUVhGlpGhtxCCxGBOGuHqvg4CZRDsYJyAzSqyi4dnWbk67K0nzuVY3H2HpaQpe1
# DATA uiT5BNNEZ8x55c635A3rFYEfLTL2aqmeuTMvBL6UTjhyT/RJ3lKVTkdchjM+WRD/m80x8G4ytKSnrJvVfeLhrIOB9AQhj/sBEw1v
# DATA 4yBjx6nVJPcsH5BS72Ysb4iQwXgnTFhqHzt32LFA4IPQx5AKRg7E2FNyV4StSnuzMCOxQ8o79YxSe5+3lGWyvQicfMBQiHaz0uVX
# DATA L19vjxHrP3q96yoOSbozyN1JypF28dLANsrTqSRycHBZjYV2jB05SHLPeJq0UkoUg1m2JpVOFPNV1IzK7lIaYYD6nyj+rFMJjVqc
# DATA 0bXm7OWR/AhrYVw6Q6jsLMUywJRWpXJuyRjMlcuGXbBpGAY56Uts9mF4GmMCaLzjb6Qlecpba6VpR+Ugs8zTm0Hbap48HSpVrT9k
# DATA jWXFxh2KrUNbktdB0MzxDfJ6g0YB6K9eouVPW4Upg3FeYwWPsWX8vW6CZPmCiq3Cvv/gViWomB95YFphb7TI2MfGK80uWq3BiAru
# DATA Wzbkg/RUsCYttFAyBQdrCQIK3c1K2F6+RI/1lWTiSU4cb0+dgSlkXGXPCu9n4lGIYuMNua15nN/KzCm3US1JTpa32JKHbNKiAZJM
# DATA vRAYpeVNBZkP+pcW7NbM8oB6vFGJtqOEA2veig1w7Cj0NyYTFxTanFJFyl+tC60jhMoVaJ+MsW05NxMdWLli6SaimyOFchw2d+wy
# DATA 1DzilbtgQf6zWRxn6/N0Hf9yIpROfVPYpLMAyZStaw6OxZRiwXgqiQ2XxctcX1mGydXMGUfE0GU5JHarE45pF4iDQyxUa5tHcooA
# DATA dXHi+0AkllvOAgs1cnTb266BRGISOEXtUyjfNEjyThAaeJfehkMd0I3c+MISE9OJOOigRisHZdsaAWJJTMqayxcTVuapiTIodKaP
# DATA N8czXzRnWAoySdH2iWHP2EkjmG1iyzzVGORcMAFpWPdSJFZ4DhZspII5uZFSKoKqA78kOMfcmzkDQT5aNMBhk2P2HybMoTIO76FG
# DATA mUxlX3GyoJoWs5LiZOtelC6G89FizPn5xhcPC5OOrxnLo+CaU+xJIwiIOT4v5BBp7UGLFcpWspKM0Lyo+2sOopxMYm9+OyN9LeUM
# DATA MiAunUoDxBmOA978CnbfNfJVFHUhZ/ji4uA+T4I2RkBn3kzSSaGpB0bwQkHJSxS/Qec2SSci5hl7yAFwOswiJ18QMMyy0SpdKdoL
# DATA kKvFsvogcxy33zygzBvPyHIUxtECNVpGFXpY9QAM7mJKXZMMx19gPEnVI888aQFIY+T2Y2dTLMl71ikemovnre1z7gqbofvEm+iz
# DATA SpGxN5iVHzeBSaVRXkfKCOMI3eV1zAG4SjPJ0PZfx7eMXGZ1ielbsVZCsCTPkKnOOTPLpx/yEh+CykdzAETu45UcraFDZflq/St2
# DATA wENvi5cvMFUvLgoTCb6Bjb5AVrCYEgcV1dQ5ucEMy1McEk+0pZy6B8uFwQdmAuyK4XlxegqF+oYxGdNulATpZoipHnhQC1Zvf+QE
# DATA lqZLTNJ2XCpmL9YWDsaBLjsvZSSH8dgEs3FrsmMsbTwMF2gt5Z4O67HoC9RQ1i6U3ImR7VvELg1des5aYnKH5BNbck2raJJhNIvn
# DATA CzzkqvRKj61WStqoljoKXQhzUgnhG2ixP5NE2xUaH8/b9QYrpJKDbhjbdqcnp9FW7TA88LqYq6NlxgesvSnkN/ESPLHLQg3Xeppy
# DATA SNTS7eDtOR1U5WAJKnG39s4qUKQckmLt2cE4pa7phCvbRekR1UmHLDeOj17UJHXHht6yeFZNfDlDLfAKXagdZnenDGvUDCkJW0VV
# DATA iJwXM3TJcpaAxEVov5oto7GQWRPRJwaFqupCSN4ScjQtJw91iiJCmy+BpzR8UeCjmJwSN1fxdClAg0wqHo90SoEK8kXIx2JOCiI5
# DATA ZY7HWVqaGghguU7SMaKDJ7cYc8oaMut5GmJ230jEsMkqC8IszXO7I0pWuGcfMEdYucpK6yWnlx0LLN04fAqHXtY+CnWkzlPH9AFv
# DATA dFZZogt+IV92dbKsV0wdE7uTRlfWH7Bn4oWoAoI2coMAA5pAjhFFLKYYXKBANDoBJRVArCfA1aDh75i4xmnMDss16zcTKsBDT1ls
# DATA p58gdUue8JL7UEdchrcqJ4VPEPCRNsq1m8Z8wCWLlbAzgamGVw6EnByT2I1EaVQKAUeRVACBVEfgApw9wUe5MFeK7W1QlfnoiJ2k
# DATA bTuVnLwETwlSDtmwn23pfA/mdZEhHZTC7rFXWWVn29mjOprJ7jd8InuP1HcTmfEUI0/V+Vzum4M+JVhQFQEuURHhpH1vKVUCE8hY
# DATA 8Khpl89gRWoIu5LKkkRwEoEcUOeDF8A2J6kkjpQPomK8wVyO4yB7IxcNBrkZaR45/KsraERQp/xaJl9VIjHpjYAB76HRBpYTWuNs
# DATA cdyoCRYynBs1kyRHThJvBfjIIYQZ1iW+Kh4OspHcaI+beUZhOFWagDyupVkQZjTKXprjEtLZC5X6pUpepHhuSHFbm7j5kIkkgWFO
# DATA B8BZAp5eQ8qMF1XZiCAD0RUd86VkM1o41XftXibhpuvQIw4sPJOkHLIcVSICxowwjkSHQhKlNGi/kkrhLQv3536rR8yz1S+O/RT1
# DATA SXT0H+tjlGSaZNdaUJmDKpYLmMNXOu0DLDRCD1C7du3nWuE3+XaZ8gEuxSs9iVeqiCajmUNcqFsEbEgnc4Y4rOEW1xleQA/apnIk
# DATA LKzYZTLVRquhTOjEnBzlZ2UmDNlsGv4hnh/NXhO/9Cxs3NARtNzy8mmnCgMQ6BImDH5UgwWQxZSzaOykIPGHC6v8EVT/JZjwBw5+
# DATA p5mFcW1rKyB5gLiGCXJjRhoGMJCIChljGZgkOB3O0BMzgtz1E6AhfMoj101TNg9FnyNc5DzeyKYgDApPpk6qmIGcsgNs0IO5ZxB8
# DATA 62Y3II/Nnen5VXUqtLBUwBNrvJO4Ig15DPAowWIiYpfAsLTtghqJGgPl85k2IvU4Caa0T30oFhSblPKvPRZOpROWrHbmT4VUrGKG
# DATA BUladCSARoYcaU0c4p5OZSSlBGcsewptfRVx0VmjxrWtRKKbxhZRHpuYKEomJ5wizjZKINu8LN3GEqsrM7cCNu2Uigg64/JEDKsV
# DATA +cioj+mMFGoUS/WfNHye7tC3OiR9oKwIAR/FcPJ5bYXNkttlIsGQoTtzK1Rtn/q0qlW58WpK2SqBGu0syr7OF7DFriVhZRX8xp9A
# DATA wLJqmpa4XVbp8jRbj1Rqkuk6nUynZNlHb+qUQgEIIPyLA2CJbN3aBrwZ5HUy9ISYMFoXEj15S0EHR7kVrXxnKQHJ2jtpcTfVlRIk
# DATA qdYSUjUHQ61kH6Un6dIYyOHmSmU2avtTj611JE870iCTFYsfRAFAu9EgcyKZst/AZEHQuSl9xsHUByqsmRw3pvFRrOWg+moKWk5t
# DATA Q/sVFUqYBzAm66QDG+N6NE9G42pp12kiFiHlhbnngeYCfmyXV7JLeKidbsf4iYXMrTojy0d3YvaDoPspgGezK4ddtdBB8YWVEkWq
# DATA Nmb0cRkwMpJLVbq56K2Zp0u1cVzTciUXFTaf/DjkBWBDteZppZGDtOK5JacXGBbjUr3POQMENvsomboodA+imPOqSK8BH3Gvmxwj
# DATA 6dyTzrFwEW1r3DgjiRVyW4MOYEJUnMDSScjzi2XK+FBrv+lHpKWM5rIOdIJAyPMFWKEp4dw5MvMoFHoWCq0ZLU1IvUHzSOLcmon3
# DATA 8EykolPC2sAoyTD/I5nE2nAwAk04DHS9kl7UmU/WMGvG5vKK4JpU+XAhIT/Tq8Zux8auJ/kSAM5Mm7gMFLrfDF/AZ0u7y3W2aMeb
# DATA 2Y+IL7290DkrdSJQYyILSiNCpUHoAWiaOJflfcxy1oaG+iKfmR47klSGub3Q1vrXrSNa/l+ArkQWZKrrVmDlIKdcoYr8Gw3QycVF
# DATA /cXzNhvknZvRMRvMaxRVUwJ7X/DZKyfFX+UO2mGLIOQSDoUzUSAYOe1DAYmWAZ5Gs5NErDN6O9MQuGXACcm6fsdyyh152kkdlvhA
# DATA oEJPAJPKjn8gEO1ZYAk8WESIWLumDGXcBxpH1vFiVCYoiumUwbHTbJE/8150E23L5AZnTxcOC8ZyTpgtPi4AY+16YeJyqqxkEdza
# DATA Xegw0zVf+IgcI3npGCQTm+gRIqYMDpZ2PJe/oWRX1Ip3lLSTBqI4P0tvgJaxYCgQmUotgVeoRJLmNyvOBbnRDkeeKu6UW6rsso2o
# DATA jYa6HBWta/2AfcGyIlx4hMbMFxwiIF3LQaq7D9AlLEVUMGSgjujw2cGEMDa8dU/jWPqiqXK1M/XX0MeG5pGJyqyxZm/HaXQkiEfh
# DATA w4RcdskuC8Xqloms4kYZk40Vc74pGIOqDeV3saKx3Mckzi6ZZuyaU8TVVm1UzormDF6VBzX1l2cnKd0cuiFEg6Cw54qs11pgm3Fw
# DATA zgempuoGmC2Dm9NwcZVLzzEQDn/fVvAQWxzRST92nFDgEawFYM0RGwKLceSRp8yoVxiqTNIFpd6zhgWq8niBcMlpuuJZgZXhM3sK
# DATA mlhXwIQKjFd8Tkns80K1UTmcpsV7PBphglNBSRZ7GjlOiaGUq2iYHIfT8cjCgXEU8nQqe5Xa7BQsENPPs8c3uxXrAWfpbTCW+FVq
# DATA pafxWSMDi/fgwXWjV+gZYw0E3N2Y0sXU6ibQUrhnnY/r8epT9iZ9p2AMHnxcoBsEg1qXylT3LLVcGhtGHZkIRZ2lEbAUzmKpm0xB
# DATA qnocjHkjImYy7bmyS5PhOCYNic5OtFoN/yWNnauiZ1P2EKbZmkqCKSiIuJu0t5Xy4MsOwriC2SqN5lQvUY9hJDp0xcLGk522yE1l
# DATA PJP8rxIGBEzYhzbUuvybnJpw2pnSLDbCJXaEfM352QNhE0dWdYix7VzWHddN+tAY41hYsFLUGlgXFJ2s1Ktf60o+YPk2CtRZa03K
# DATA NahuU1Rt9XFlbzmpeFQkC3L88RleCVYVUVL30Osi6p+KFPNUV4JE4SAqQ1VQjdSuLzt0WjI272XPdpvShExxkbosYzpeM2XHTJqD
# DATA cpJ6skS5OpVNB6yo+A4ijV1yOTXRqaSOO4CCAI7M3ONDiAZmS+kKyHOhj8Vj1b1sHGF9J81t1rmCi2NYWwzfJcEVFIgKhcelFig/
# DATA CldSNjhnhNPu5q1tipBwtYR71BAeXaa9iizQTaVOKWKONLMOqhOtRBT5ltbcKTJ7mN4qF4gHTWPxPXEoPJmzb03OUGGgPhVDhQuc
# DATA UiYQlXggK5ZCmVVd+Gyqel7SfKlWunmHx7uOpwEfPqQy5Qvx2HMLu/JhDZlM6q/RKq9J6nbBMcKJBqxR6PKMUh+cM71XzHZpXoow
# DATA 7KPW1O9ytlFBXcXCHgAznXcbs749XQKUT2StTA+1VQRVusBN2yV3vqcrZFNtaMxdVCd3oweP4Og88cAzJXv1IIXjAVowU8TfLe7L
# DATA jgRvrkOc6Pi00k/VYagVc4U5oEcxNYnJJlkUg3SXbGTEWKeS7RFKDREUWWW+6XSHSw5sDCe57WvRFbSqHT1C3eZF3iN40XJYn0L6
# DATA kdAJbYmxbSJp+8ek1mPVvR8XiUWVz9P+F4mO6HIxUlkURYIy9Quk5UtlDitp2FtyXUvBTda5lGeFAeNDcmXnCD33TZY72ji1Uy8S
# DATA PLoIAoaTqFlTUYFLTzowZ8zEv4K6K5PDOImvY5MUQXsOC1Bn+SLgxChWk2GS09gp0YlCdeymtmEAipeZ+Zp1Wt02hclSwyzOhbKt
# DATA oIXYvPUlI5mOWlP0r4wHkTpg5+fGuZiqZSVdtFqmi92ofFsNmxIVng5U4FxVzTnbMlqynaclNEIJ+Aw+SgPHRc2ELM4dLBZlzoK4
# DATA Q7C6R45uiifr4/ekou4U0QIDrWFdjCwhYZJmt3QCtKxQG0ffuOQczM3K5OHM7LquQ5IXzRXWpXNTYspUBGCNwBg2hVQhrbOYdCA3
# DATA JXS11WFVOjIlXosGsXhsSGU1Ri+KJEOcOrRnJTVKhM+TGNIQ9UZJ5DRH/sgfpu5dYABNAggJwFlwO6Gco9SEC2QEp26ClExRPlQp
# DATA VXfLifHCUgqV4uzxin2zTlZXRbQ1mzbOVeYiyh+3tDeUc7VOx31s8ikye6qQucwT3FNrDjvTiaySSlPlPLYklhsgxDpPc1UbuMaC
# DATA A4MMAAcd/+NEy2lUNrTeoJJnnovSoY4j54ofUsy1ZPtKoARhi8kjEHFVAiFQw9Q8fcjSxQnWtRe6rRu/envDfxFksFrtZnPA2T5X
# DATA urSp5dzT5ySosFm20LE7MZ6t5BkyhzENMaH6gGJMmpsuRtol41SzlvQR4GtaMR7Gbv6idqzb8Us1TSq11Go3/MPUP1mAdkENYa2P
# DATA qLJYxX/O13yw1laoO8fOiEgqZvlVZQ9SWbUFVSzhUIWlMxpAayqbDFMYoiTUKfFqiLJg2q2qtAZIRCGL42of0Op3dRgBPT42i3EF
# DATA e57KAX51gCtPJovxPJjGXCiHM+aWKkU5DgBVzkOdy0KfBE3dvCZiZcnzbjt6BEDg7gEV7Cg6hRQ3RNSSo85EudX5NYqik4YLFjyW
# DATA /VCWGyk++iCj1nOs3QpvAWuZWKLeKyREyvkQuZqJfX4abcOUtL7UuTzBwZI2uSmUMMpw+3KOpMoYcw9tmRo7rU4D7/hKYX6HomPv
# DATA m0rjTzHX2midq69R+bY5eoJ3k4boaaQQdSydGOE0BqtqOFu3+iYdT5fTsKrfZzTBsTmLulwsnbL/aEgZydNnMslWs8qv1+hEBz3k
# DATA i7ys+M2qYppagKl5sHKnPN3OtSOlx0wfPiZtLChS93Qha30IPgAZpct3yanSQBe10Ke45foiKdRSCgwzYruO7epz7xJ9tQ+264s3
# DATA POvijRVXpKiEIus6osjRvDnjQ3kctK/h2xKkNnSKBWmmr0VaYpmSpRiZ0pScezgkj7n0npFVN/zwGUM2GzxTFMWUwbWrXxRuspAj
# DATA U+U56pT9YZ/fcMp/UE6YPle5XLBFJV6buepDF1S0QBdvIQ2dzv3auVNqTz0CBciTusiTYIXg5S+di64chxvOFeUpkJsUOngOllwk
# DATA Z8UCU3Ytk77ksi7rZhvx4z3m7iVm5xgbRJTBX6rpCCiwu/MIAeg/kCqFWDhqlmSJPo4t6avmkiLELALLWaX4QoTHhvAaK09uaKEh
# DATA gGZB05iIzgbyLZvqkKWiMEAPl4El3RTpYgHzR/JQLaYLrKao0wU9fY5A0n+VsaHzxfkF98heOcK8AsLWZPfjgRfjT2etSVSvudlv
# DATA BA1nzxN7snyIK64MEpeOSsZTgHoa0ExVpnMg8J0Ll+ZFGvIMDS0nVWrLkNF1a92txMMrg+JBcjIZiOFVqkJgqi9yc2owvTIwLVJn
# DATA XdIGc2kxgXbe3PJ9fPAkUnfdjRZYrMkr3iX38F7AnuTYRl0XU3lzW8nFdecmELrheoMyO43IigQpNYvxQr2rN5SHyagvB7S0SsHX
# DATA M0HEXop/zs65pZpQkr3t2Wc+rFLtIFDtNyz1tKCk4yl1SYhPS3KmSB+Vu+mU9KdJqYsmicRBZ3bIE9lfr6EPBzBJfSXHA5DpfbF3
# DATA vOfvn/iHR/5XO8fHO4enX/vPj459eOC/PD76/HjnRd0/PaLvez853Ts89V/uHb/YPz3de+Z/9rW38/Llwf7uzmcHe/7Bzld4L9RP
# DATA dvdenvpffbF36B9h91/tn+z5J6c7+ML+of/V8f7p/uHn1OHu0cuvj/c//+LU++Lo4NneMV2/9QRGpxf9lzvHp/t7JwjHl/vP9myY
# DATA /LWdEwB7zf9q//SLo1enGnjv6Dl08rX/4/3DZ3V/b5862vvJy+O9kxMAAPrefwEQ78HD/cPdg1fPAJa6/xn0cHh06h/sw8yg2elR
# DATA HVGj2qreERjo/8Xe8e4X8HXns/2DfcAX3hn2fP/0EIYg3O0w5LuvDnaOvZevjl8eneyhMEUUQieA8OP9kx/7MANB7J++2tEdAXah
# DATA jxc7h7t7OJY1Zw+WCafrf330CqUFzPvgmYMURNSe/2zv+d7u6f6Xe3VsCcOcvHqxJ/g+OYVOvZ2DA/9wbxfg3Tn+2j/ZO/5yf5fw
# DATA cLz3cmf/GLG0e3R8jL0cHSIJ9Rt89EAH1A5Uvjuyi0Oknr0vkTZeHR4gFo73/vQVzBMpxHcpBPve+fx4j5Bs0YP31T4AhSunicJn
# DATA oqjTK/DAEMXXQF5H/oujZ/vPcUmEaHaPDr/c+/rEszECODbkuvPZESLlMwBkn+ABCBBDuGbPdl7sfL53YlEFjunJpcd1/+Tl3u4+
# DATA foDnQIuw+AeMpsMTmCsuK/wgnfg7sL7YAxImr6H3CjYBEt+hIhoYG3+zga2asZcJ0j84OkHq857tnO74BDH8/WwPWx/vHQKiaH/t
# DATA 7O6+Ooa9hi3wDYDm5BXsvv1DXg2cL23v/eNnntpgRLPPd/YPXh0XiQ5HPgIUYpdEfNZKcIuTWt3Dxff3n8NQu1/IsvnONv7a/wKW
# DATA 4rM9aLbz7Mt92ooyDgC5LziB2VEPgkekvEGDDUi8/ENT38nSESUjtSKH1emTUNhs7JCwObKhC7dwnrY4IYaxaD/jFAta8OElrqos
# DATA ufHCefmAHCeYe6gcxjdsBS3I3CPjhrVj6Sm4UYeHsE7pOOUzv3i46Q3dBpF76Dcd5ukYqyRQ0WhWPlDlTq6TsQV7iV/OMXtVMrJz
# DATA JswcRnERYY6154VCZDolAqs6gJh3C9sC+dFylt6g+AVfS7VDGODMv1N16uBrlGKHoI5K/7kOP8rVRHJz5My+g4EradONUxJeEyAv
# DATA 6dBqDqI4leDdIi8cEq5LWC2fczEpzPC8onCMzhSWkGoy99wraVnJidW95HwxhnXtsnX7tA5O5uYswqmkEtYx4z4QX7LRS9WpOK3X
# DATA q9TRfTKJ8mCEE0N49dsTfbHoXI7gUMaZdfqCL53BeKWqwT6+9UiZEme4VfzRrbdMPVEX+RU5g0ipVkX0yMZZC83VlWM2YvHKw1lK
# DATA vg12UqmCR6OFLmqLsxmhtgk4+SEikt5V5fKsuVdyOkkm3Q6zJB5h4C3QtaMkttL4UeGi+R9icb8f+f4P6fVUncL8EZp4Sa66Jzjs
# DATA Bd7St0w7y5rMfedWZi+ZlwefH6PpBvnjFfG6MkmWDH6Tb5N5VfeocG3ZQmksz9tMT9+0dYWBKHVIS5mdsH1g5dhcV4oW8n+lbD21
# DATA 7yfmfpST3LCbkVfUlwCXq9Ql36hLJ3H8OONH7rCne9PR1FVZgTbl6vR2N9Hywb49p/6bwSIbc0DRmBUT+z+8ms9n+daTJzc3N43L
# DATA 6aKRZpdPVCbQkx/REb6cDAGnAg3WemHuSEESvpacCvajSzhLp1jSCy84CWaY1ARz0/kZVj3GMDAXLTKkfNvxPW5KT9/peGsQxaW8
# DATA 3evmk7mSjixDdOkYvtWbszNVxftyL3hmUx70EQ9VqIOpHO+YMfc6sataVSgO/DV1lRe5zPicXBxEuYaBY4zAxK9jT0fBIp0gzlfw
# DATA cEH529zyhkt5TykwRzc9aVOOJC8pGGonDOP5XLKezHlddQHTU6IBffygowxLHWAtFpn7uoB0RCNhKgbEpbeYWSKebHNTgrrfL85q
# DATA lFWHth9sTb5+jSKQWA2Kq6Epbmh0oTWTTmFd7W7dCPJc5za49IlE71wvyZoM/iAWp95HdAM0YMJ7cDd87w///if5BzbI/u5eYxL9
# DATA Hsdowr9+t0t/4V/xb6vbaanP8vug3R18z29+FwhYoHIFQ/47Xf/v+ztz5/J0fRTL847jyTTAWJCc0OajzlxElN2h43Q+B96L2dzT
# DATA eCznwCKU05TtRj5w6uWGtMtpJDWuiJesdxrNdQxjPjVnXZSWzJfmUskJVmHkyg652bJBgYufZCyuXuvKWSiqFjNJVXsBQ7QbTe3t
# DATA k1Nq2D+/D2OjagrK4JwuAzJ9pDdTsMx39w5RUfkMFDbMwU7H4fHprlK/CSWqzH14a0ryKaA5iAYwm5yWr06fvzx4KkEQyooEyQ+I
# DATA ezJVd2BeZuJKPsUklHVOQtGjoNlGN0moq6noLh/EtFo0kD2v1PwZ0C1fMetL0BwWwwYg8Umm1uTJMAhfQ+f1+1vBQmJC70PNplRY
# DATA tKTJT04PTp7gcq0jOiQWg+d76FZMcu5iCX4mGzl0c+9I9rvr9G51o9FsNGsK1YrAGmBf5Ya+aFF396zyCw7JMQ3EaLr8O9n/eC8l
# DATA JlA1wp/m/zb8v93sDQYu/2812+3eH/j/d/Hvycf+8YJKAqri5mBVcgoFsSaw96iW7BFfQKnrf1wFYOLmWPQXfVchHu+iAwbAWj9+
# DATA 4lXQL8PnsipPKSF57o9yf1vpydUKsoqtUV6pqcdhdjsD7bPYhH82zd76L7MknwS7Y67Pwt/8O/vFJ2AqPwE1lvjRBVj1WDjvyR/P
# DATA qOmTkN40PUZDeLdarfnbP/Lfej78w+Re/oT/uJXckA5NDylyV+WBP21wrxJ2/rTBvX/aAPMmmVcrjUrtrHnuf/qp36z5P9r2B/6n
# DATA Vtf4L4iCGVgeW+QGqz5yDvLS+uyyUmswJC8va1W3ZwFeXIcnc0xb26IUYbAJGvH0uoEe5s92TvYuXh0fYHGMN1t+u35PH6dgaaSL
# DATA +Qu8tC/f8lvNC9iuYGiAeCw86vAjp6+7OqwemDXxJODZwqjVVeDUGnmMVt/LAA2wBhhQ1Qq/W6khOivs7qv4dzUzyp2/ReyfbmJ/
# DATA qn8Wh+aU3JCGeKqypjVueQd29hyUDINENKtv6LW9LEuzauWZMEs5lTdWJXKxGgNey0hb59a351FRvXt3tSrSHBVI3r2Kw9fUqeQr
# DATA 5zyE//bOe/KElRMlsjgAHvknf3pgKvOBcU8FJgLOJaWjIJTjzJVydG0T6EyFWFltgZfSDPSnIyq4Rw5MMOexlnGCF+FQaWfe2yQQ
# DATA TX35p9gXno6J8P5aX67U8ieJqCycacVp0GCXy9U2ulBKQ3abGeaFehM3FSO90m62+83NVqvd7AD5XMRZcBGM0a6/0DmVF1RKvrJl
# DATA rZPAQkjNF5Mtv9LabHaiYLjRDkadUbvVb3fazW5nozdoDjq9ZnujPxoMWq2NcKMfDjeGnWijFTfD9mYv2IyCuDkYVgxNqZOzqncg
# DATA 7jOHrCvdMBq0R9EoHkRxrwmvB71oM+6HYdBqb7TDjXZ/YxQG/WEw2Bx0N8LmECDqdZrx5qATRr1oUHG3SSUcBb3eIOwPh5ujuBuN
# DATA ws3NdhR0osFGq9UatQZBazPqt6JRByfTHm10Or1BG2azMWoH7SDoWf2d88e7unen2F3Ot7Zv49GERYxM709Ojg4bObEHoN4q/V73
# DATA qxd1/5qY4vx2FmPZDH97e9uvDJEs5xXgY9eNecpcBZjnFjRWQyD92AMwD2+E5L3/Ah7CVr4K2r0+MC+u91plqHjsWq0RJZdxDjv+
# DATA Kn6DG0iVZ1b37sXRQQxaYK5gnQVzHPDsvK4C6EBRdzUhkWTkc0P/j/5IT4ZhwwlxNd0KPvxoJwMdtZHk9FegoQfSAZW0mIbYA/AC
# DATA efbZAv1F8BZ/UJNwCBSBOisgGqGunQOoV4QSgaNm+BZ6dKqMUixeimnB1KaBJbn1MKU4OYMmgI2zRqOBw9R9/s6AaIYXj/P4UcDx
# DATA WPyacFN+7al3Z63OGFQDhTWDewflHyHKeZiK/5d/6X9EPzcowpF/Bap+tfIGtn1rqwJTk6GoCQ/O2BjeYvmcbV8wj+ZCVfpBQ6ja
# DATA BzOggoy631X4NGjcLtDjJAg1PdYd8bjz8uXFyd7u8d6pplMCbh26wQmsX7cqmladccJkho79wlDPYv49ua5WgjhfhxHXL8NJhVan
# DATA zrNqgGUTEPWBYG21a6pbehFk4nwHrJbT4LJaaN1q1/32Rs1dI8EPpn8F8+qZdCJTKXSAL9fVOFSsqFo7r5ktXlnMRxuIzTsvyG+n
# DATA oa6Z7ufTYJZfpfOqYpVq8RkXtLNxtcByw4jOsPGDv1jE2e1xcPNqimGv6trJ3sHe7im3vKCgzvPjoxe2p/KCZX9DOvuKslq4PT/Z
# DATA VgrBmrMQXCRxm4T4CegQ/H5jEsyqc+JtDTOoQp617WZ4lznQ7tlZJYgmyRSWiijggr/hDqtoo/QCVgdz6HLdquTR+bnNGHB7EIgN
# DATA 2GZVHA20ReIqhV9b57WapY8Y/aFaAUhHY7nEGGPY4a2g3KgeBh/oMDDyFv+Rmx1kWiWJEG5YyGx+sVjwN3yIkODneZb+NJheqJLK
# DATA +NM1hp51Y/ioH54bGUSowgHKOlUvXCCbwR+ydBzbb+PskssL2JZULg4UxwWeUV7GrDzhGdskYEkE++dkOsRIHGwlmz6WSeAsDKYY
# DATA p6E7QpJ4HOXnFieO8VwzMF3Cq8Pz+W1ZkG1f98JCh+kHhKhNTiBE+WvF/8S88LTQpZLfhkJ0U9CMrYG2rCYMBz4XiBhdTx1K/Ii6
# DATA hknQtwLERCeVVURIiXFYO5FbPdWZw0+F/Az85nTMPSyhIiwhxIsap/fzBG5TyhR+0KJsBbPHt3/Q9o+OMXvlMwxTRsjnLmZpTul7
# DATA RJDMRer8Tq2IfDXWttYLP20YCjn/VAMDoo2pBT/pKRPjCUknalhTqwHDxWvD+NFHsFWIRUcXwRxhYulB384bqkhBNazV3OWToRuY
# DATA zi89mYHpxwB/DOyRaW2hp4fWVSsZggG0LxwqXcJUEuH6uuMvz1xoCzkDEid/wn0Af4o95hQ0jbFf1GvUlj3DeoXwXaZ/XjsvvggT
# DATA u1f+/Achth+8VUOYdaqsVT4JP4H/1ho/TUG7qdQrtTsmxbUfvCUiuVv7D0uzFxMKmY5iG5/d7kcWFyqwGUQ+sBUEtVbwEJRsxgJX
# DATA rBRf0TvaVWih9wa/+mlD+B+MhlqYeaIfNMDquwQlcAVlyNhUzWeaKnaa2/pryTSlmUy1OGTZNPRUpBEI7EsE2eLfxOGsxw9SMwZ5
# DATA FxyhjjVI8GIZ8DS+NVYQRc5Yy2/ceau/WaiQjYTaRZlsdaRpzdrglKKV3tTwP2f8E+rprHxbvxUgY4o8E20O2yXRudHwlymfujqv
# DATA FboxtFzWlUhFVMj3lGRc6vgsLPExufRdojihUsQgUROUXuhLQ5dP0QISyJ1BnIncFS0zw8FxhwonqWsnJ096y5r8nct6S4VBzVEj
# DATA SMVnW6FMgVA9WO83ePhaGT+Q1USrjkwq7rhs/wixUd4a8h+9HrbIKd924vkcR89ZkhmhZ0PJSIGZIzCIgPOnqzex7kwbd3gut/wF
# DATA aVBAlOmBZUr1jA1csv/OyWFhLE2LWjV08B9847xs55b8RhuPsfcwRxQZiUEVjfKipITPlS3+SboVweJXipvtrkCxd+UGeMEewxBt
# DATA 1TbAlU0bZJfXZ23ePwBtDGbD5dW8sqy1TmzX3IM6mm5NEh1sSPGU4b6ZUibcBZb84EpWFxhwhO8iQi/YoX1hRlyrLAtT45pEJ0+p
# DATA /EzwKkIsT6U7Kts22KrhAlIzqqq3TPyso1DvDXeeT5c6/+jJn58F6z/bWf+z5vrmxfknP3jSwGRVMvBYylI3FlJWURIeXsQMq7nl
# DATA Xy3KJjPiCIY7f9vv3qkBaRi1CrXVg/CNLcaDGxoHKlAngV2GE/G2mRCFBCUM6p+o95HWze+N/C/GlbIelT9nlDfiN7DY+QkQNLug
# DATA gMfDr1i25zloG9bvRQPGsrlG0BV1+emS+wJ6oprm1SffZN9Mn1zCpvtmCbWKZYrDV/UGoJzRhzoMgf+zOpOuMuzsnEUdl8B6pP9T
# DATA Whc8nzjLs/OSddewGXOguOirJAFW4pkaUQ2C5OhmWi1zy9eZBGDaZU/P8OF56TJoMHkspPwSgOlho+C7533Cj5Y87x8yWTd+Y9P9
# DATA Yspg2TdGaBI1pO9/Utoneeif+ogPNIacHeNAhaT/VIdJ3IZVjY6z1jnOuEKqtKinS2JgWY0khU4vSmO2AJoq2a93JRoPs3PtsyvY
# DATA kFanStgp6ZHPo3Qxb2BhfOD9XyLvoMPVFndeZiU5T9jq1gg7xJC7+cqH0lE3LbLoXq84Mi+LK3ulsFPTdWRd6WgSiChiqQDsQ+Nx
# DATA ILBEsuo6rNscdpkFWR5XixyuiV4y4lcWcgogaWfrQ+h7qdUScs7U5UJPcjlhmjgGEPmqaLIlKTVGad06GWBp6ry3CqJEX2XHfmJW
# DATA RBoUVq3GFN9EXZNQkY7jBv0kD6zIihUc/dQ3q08kJaFWpip6szHBDNfLGJ0GK9pKWFZHVI1fv26RLNPorTo2rH2q4jLGEi1WmgNW
# DATA o8GyNA10dumgwZtkvoupXNt+6ylokw0p+i/ZBahDYcYux9OruLj/9vk/MSYkY+z4YhzcItnMbr/b/J9uu9fqFfJ/2q1m5w/5P99J
# DATA /udHTxZ59mSYTJ/E02t/dju/Sqcdb21t7QXfSOdzOVpDJ3wSP7cMGlII1UERMmpw3zxLw9dYOwn2ZAO681QZ0eySmJ76jsns6vNo
# DATA OkFeob7+NMdbtPlzmnNJExxrnAxVUdKX8FU1yXSf+W2uPmLlBfUZnYueBw8pJgraBPDDOTJb4IJV7Kl6cYE88OIC9US6WhvYF0CL
# DATA mllND4N3fkykwoqdh2iMGF/PbTIJMGuSElfz+AKZk+d5UYx1dGezOFIRbLBqMZfqpralrLYkVyxRtQEo5bFlBSLo+B6wQw78gtiu
# DATA 4o/QY622dY5dqWC3r36nq0WtuCuunX6JdHYQXcTmqdVqkMbAM5dhOpO5oT5kTY2vSEc7LZGY7vnqnrEi1XLPb0F2bfn3dE9eFmeM
# DATA Bn7LqzXHduZp8UKotUGayKvskVxaEB1EQnJtRHE8ww/SuqZjRuoOtESZ55K4xD9jYPAtSAUaHUAy05MGZxXYg0SCFXREyTxLHtrT
# DATA BvSZJ1RARICgBTw7d6zla3RtxVYrBpB/RvjOzi2wSlaHGsrykKjkX7gbjPQD5XCayDSqbC0prdz6rMLZSPYsi0+sKTozIN0c4K+K
# DATA E5yirXkMonmeVwqwf98/EVzQDfZY5UvOHHKyRc4FgTGjiBhL/lQyq6M4HAeZVcZhGI/Tm8aSK1dlhTjYZC/IEiLvJ3XCZUWvIT3a
# DATA KrVAeJtXilTi/FxE3ojKS6eL2WMw50zMImPqYBUF/2vM7tvOzBC1vekMTZdD/BBhV6IYl5QBtog8whz17CKdzaVvdyKKju1m52eq
# DATA sxKCX9GwOFHH6yesC/RuEE2gtKp5JeSlFbFThc5IBmNnlRkt9/o66KP84S8WSQwGkWSq1hQrpgy+KF9m6uc2GCiaG+M0iJBjlowG
# DATA eMWjCTDSx9AZCE8GWG/DqMpeW8knJruEcwUxqIV7c/swncYyrZEUw6eWciJeXjNwjgPYpDx9ecjrtUvELmRAvxxQywqJwbd3NkG4
# DATA IPBxGGrML8JUGzzJhkiNhjRlrue+vlV0KpGX0VhryHDQofm4ERp4UhD0qosoyXABK7XlKIr/8SP7kvghBw+pM5WwXC/v92yCRY+5
# DATA Xz6wya/J0dwFFTsvYv4F/i5C5fzcxnMwlew6pZWwT2+VWsJPRS9x2BMhsbADhURPM0G2fH8OVpuS+WhKXyipXEWtrK5vNeVE5u3W
# DATA RlP6jcA0p4NC21zHa5LCHkHVt4owSXtqeXNFZ/KLjX6ou7C4j7NTGYJVexQ2EQHn7lUiKqoZinrJh25IYn8AQ1FJgJ9Rg5SOiarx
# DATA O4/Px2bG42oolICVBuyddbyYTsmDxVb0ilZfxMF4fmX/gk0WuCNRPB3S5T6VK2p1KyseEn0JVKXrLQ+LZPYtgKCUhKka/6Hhh1kc
# DATA vDY547j4+RgUxGpbGHeAZWG/RIoVd8nuzuHR4f7uzsHFwc7XR69OLw6PTi+O93aefV1RjFIOPF8splg0q5ql6bxujr/ZfNNikWSH
# DATA oTICtoe81Lgcp8OqfhH30PrHlZorBvkuqAbWcCD7qwpf4jwMZrF5E0k9q6x/E71tde/gzycVTrttsI9YRm8k+UV+O8Gj3NUaX8A5
# DATA 1w+AcfGP90iB2gNMU/CCpz1gdv4TTPMMXy9m+ROgArzmZJ29GBV4pMErvi0mXWPyGkGapFG83UwHeJKBH+TbyDtQIIF5c5G+pq81
# DATA h7CkI45WFPUgA6Rqh5yMokZV9YuKjqyjIwsN0wb+pwv25lX85mxrwwpf0zwALuv1IpmIQid0QgVAbKzashRM8R2Bj/3gkhCm6kzT
# DATA zSt0c4wplEw1UcDYu7YUabLpib5xIXg9jNUsiXaK7LYZJi2X+GfSP4sH+SpaEzGv86kCUFzpSBK+hqdiVrxuaS5LO2//8Mudg/1n
# DATA F7tHL14eHe4dnspolndjm3wKVYIXOCjd5AwaVuVcw2Ual5K7+5iI/j6QXh2e7Dzfu3i29/Lg6OsXK0Cy+iygGGuVRgGHzyiuXcYJ
# DATA bJBgZQkmlAAl9kXVZQQV0Ry+aWTqMDDygI27U/hv/+7PkBN800Dh4/CDMsNFsQhJ+/Iru0EU3aIK0hjSNX/rdH/n+vVsWinrQF8y
# DATA ucRnuIIG/4r9VWvntjZrcLSk1OK+8CxhQb3g0sM+hK2fJz+L/R/5G/7HfqvZ7qo/NoZN5/eu8sHe5zu7XwPdHT7f//zi9OgIWP/x
# DATA 53sVtVHUTsVYs1HqeRfoZ0lOALPMNr+LknOJd35knB5H1HuuBQPQMN70bAiiqrgnvwbkXWtkJCoqH/NqFkQE9+CgvSCEVxH28d7n
# DATA +yenx19ba2pgbaApBKqK+NRIganyWDVuH/D5ZsxbUYqP7UYyXbn2KzotyVIQLxGF5tgXY3GMFya4zrZAYVKOqkldWhwsj5+L+lxq
# DATA 6jPglC7GvkV63+UosAJ8WsLsap7i9/1dHsLcSZVMBRU6UDNP04a/w4w74lpOWCkmn0tJk2AqfSnvUN1Hrwyr63XJrOYLvNAHwNVP
# DATA rSue8nmKhqr2bXgmH9tSXW3XJnPNGqmuAiYy6Y8piVWZYfBsmq5TQZgZXpkb698AznVCxEJl466vc7YvfmayJCB0taui4mu8cZbD
# DATA R9pEi8ksr+pXQbxPsQzORZCHSbJN1gG/yh6oC2WfvaXVk1MtsBWsr7gfVBm3qnhMLb79xHKfluVEGu9RQTg6pHW3BJRKGnCGIrbq
# DATA Osg0gyWJeZlM35DhV6nVSlRG072z8V2+upoJL3mCHsVKl7fNMh85OXp1vLu3inUanqLX+5NtCtWCXiWaUxBdzOM38yo8TlGf2cbg
# DATA 6vqG9DDDC9IzSnU6m6evYykbS5+Iw2AUL0KrJ6tUKmd//k2+Vnl797R+/gl8rVsDsyv2Y3IY8evQT+XTwvcz850ZNG1HGv0+G3uF
# DATA ++PR9jfCZvV/ip7aurhpLY+tAxIg8sz2fOVFoCx3t95X93q8vbJd8AiX9O/khT4XfUoQIFbHKocnz32JnJHoV7gtl4wUs1/xZPky
# DATA Q6gVlDhrGPXaNu/MNNPlRtjXIaZLXrJxCl6PJc/HI9RF67HawRpSpYSzFLpHP7vPutONnJVY0ZnRFmVos9XuGR7VOIkjNuRviKLJ
# DATA HBXF3V5T88YvglziAiuTfkpIpaohhC3ReKI5Dv+iHVe1D1dHeZXFqrKYdSZ2kBi9FcsnYNGzfls+PKE3Xa6elZkvVfldmbUWu89s
# DATA e+axut9nO7s/fvXy4uXO6ReVWgG8Eut7hb0t7cMraFulpqIaajNbz7NaYWt2nVWBUuPaeXkJChGNCR9ZPHtboZNqW/bCquS9LRUK
# DATA blDQmH/lJS+6UCs4gOrFCEX81f8jHwYeDO5W7ERxu8tInNOjZg4KPOhgCVYOVTbYW0vB3CIaNPwHFTN2+W7xDO9qwu6v2Ww4V+Uv
# DATA XN7I2zimS+8Atp8ls6qBr85drVAAihS2EmP+R9s8wplC7/ljlAPRCrD65Od7zy6evTreP/z8Yud494v9L4sqQokfxfYSuY0JJ8o8
# DATA MVyKPfz+Z8BR9lRpg2VkMbPC8pzA4qinWqlAobFLNtu9uhVZ6WXwq7m5PJVwxkwFM5aqlXf/7/u/efeL93/1/m/f/dJ/98/vfvPu
# DATA t+9+9e5X/PHX7/8jfPmv73/+/q+gzf/GD3777pfw9Zfvfg1//xr/vv9bTsBC8lIeKSdKpeo1SoR9HAfTxezCGGtFh6YT7FnKq0C/
# DATA Tu7rLA+0DplPk96cG8p11V/XWeTwR0pgXrKBkYEov1zDMjdWEfS3t4CXFGu3K55XqXHMEsWePWppbz/+mO1cy7m2VeYduytYz4RL
# DATA Wg2jpJ3f65PgoeN4umSTc91hZc64ZoRl4SympMdhDj6b3ZZ7mnIP2fNmJoInXErlXKnypdmfv23yekq8eUWTWzn39OukkMbTxzmk
# DATA H/LA1qxUj3hKXgE9knLmTtHUHYOdVNwdJinoQZfot/J+rvbgiuNoxV5xwgr2hmFK2PbL3DreMkWYpa45S+0roiohnPvmqedHgZX9
# DATA w5PTnYODvWcCHIXV53gD1n3O3rqasobm4V0Bs4LOUXnn7re+PZV8QPxnOSMMerXgEZMBMUtTQu/YOCp1XX+bIBD2ReLHzPb7/t4b
# DATA PF2ZzKm6UTYNxk+kGqJRRjivhi7HScZ8qQvL3G+PtDIE4AAyXR1/4tVZwgA2M7pZFF8rlLm/PsKZbwJ8luqbOOkPRIV29oPQoMon
# DATA OGfWKKA6OoLVCz92sHG/G5rjjc/28eqPo+OvYXNcvDrZMxCWjUd3i2uUPRjQMJM/RT8Nb0I9onK6SIYFyK7QCrBavm48dve4BI7a
# DATA 45IzighmMTe8VXkA6Or73YeUzoBB+dbEZNA7myoVCvAW0nhala/EAfG7AYzGRLN2eYtWznbW/yxY/xmeADMfLxrr52+b9VZ7cFep
# DATA S75bpp02SkGyBniM0Hh5fPQnsIRAMXgPjFlJyrff9kvcwPyYQjvlCQqS9fB78xU7OU2oq9g4/SGrLwxfmdPqgagda3V4KYtGDd+z
# DATA o3YTB1G3C/mlPF7dlkLcXEo+WGmfzOhWNTxzXcXnHPbJhCWgrGbKXFeUCayuIrpdsQs8q337Eu91oH5WjHDW1LYoJnnggI7Tuc60
# DATA bpCsUm9Jc3koY+RcNAeOORT7djumNbUdQ9yJ7GjyjSxnCFTYP0DpAeQYcLMiVrsK+P0HsgVqJWa6QGKpTRLpVMa6tU9WvalWz32R
# DATA v93/JhYHNF4BtKrEIYBJ3ljPJ5XvQlxYfEcWY0thFJ0dvCLUlj6J00CdpuEiF155TKNIQss2mABvbxKWjewp9Uz0WIY7U341PDoY
# DATA oC/yYp5ytjvSbrXg86/V73O6qGjbs3gU0L1rYLOP8RoBXcwQf8lUaVQ8SmiOPbBDhK5DaSwFVNTEpvFingXjCzVB1V/Oszwj/XMm
# DATA 7siVeLMDjL9PTKyiJXLxFGhQw1GzAtDZ7YXm+BZVKKw8Iu689XsyuSXd0F+2pnWTKaDpQrUrOZ9hc2ElWcwrH22XBQgKaClfM7K/
# DATA adFMwFA55SznvZQBEqvduD1EUYZ1VlaNxQXkmOC6MW6WnXwFgYwbnSWqJDfil04TcwctCWqjoaA2uiiQh67nTQFr7XBQv6VN8ZHC
# DATA hRPcsEWDpsWtJY+fr6wxiZGWuinLAddOw8WUqc8oBM4+uVfk1lkRsKns5qJMaRKpW1taFfXCg6qSZHS7fhfi2UUnxlLHi5nWrMBE
# DATA y/WX4SIZR/xttuCsVKr4rBtQpi5ShozkjC5S5LGjR1qNC2NQ7pjePxiuj2VU159rMmXd3F8DRelry6FX7meZUKRSRFW3PlNWxHmp
# DATA BXF2n/Vw7i1nT8nh1W1LD+Iz+GWnTCTPZyUwe9NrhgSDq8C5pL0a5d7mNkrOKvtYH5x9dOZt+bH8AEupF58uMDy+oJsX90+/Vh79
# DATA kkww4BMXEhz2NeBVye45xGgNSDr5+izGW40lxUeS1W1+sSJObsXIOY7M45UAg+TzuwLzUNT+8dCww0cD9NG2Dd9jF+PZ0e6PYSW+
# DATA PDp49WLvMQuilHFjY+PB7xNFyuXjWjaGzJ5MD5uwoop7dk1JzLp9OsmRrsrgKJUConqoXjx3GT9M8mt/Dvdln1fQqs3yHRX5k0qJ
# DATA hHkg3pHQifP5bQnpAcwyN5JSJslYvVM186qVBTXKxZnuuG7hpXzZNQgfMQzla11QXFRcQ79dmi66QvJSEA40oq0HJrEafrcdw1T3
# DATA l6Sv00zOxisZ7cj0+0OClHZzXZTAjvZVFIylWsGHq2Ucx6b6A1v31Vvz71VfypZdv3yP3uQMUr6MthJX96topNSxJEtcc1S68k39
# DATA gCbGfVpdLr3saqVoNZUk+Cst9f5Ef91qhfr6uzCvArW6PGzJSnZSCNxdt/V7UHzV5rH8GI/RO5d1TqVFfqCm98E653enb5adMFtq
# DATA aGLzRj0tBpXKoyCaEakzSd6jokZ2Y4mWSE+ehzcNXpD8uLggNePiAuX4xYUc46aqDRkdauEKDo2d7HKBoZyX9KQaxVqEbV9cAC+5
# DATA uKhZb2LQ8yKQV6qASAQPC+2CYrP9kti13H4SWR61Fe/aZ0jCqxSRvH32mOMh5/d3y5kK6ya/KqCaetsVKvh0gcUKlXs3o8LR0hH9
# DATA wa5UkqPD4YmhXOYNlQgh3RdodDlLgl7iVeT3dSDOWy0LdakCE09+RD92gsj/8+4X7/7+3W/e/+/vfvXuv2FeyC8wY+Tdf3/3m3f/
# DATA lRM/pGzm8vEYEYZVo1DW/aMT+fDj+JY+LXnWT25hwpO9N3gA9d3/9+63MPZfvf+7d/8oMPwDDP5r+PtL//1/hI//jSD5Bx/zUfx3
# DATA /wS//AMmqLz/PyhF5TcN/93//f6vsAX9+p8Bdmj2W/iJeoKvv37/tziv/5+yXH6NM3vqv/vV+7/Ggd/99/f/+d0/vf859PUvlCGj
# DATA hnz/tzIgps78J+rrV/Dp5+//z/d/8/6v3/9dA+jif8L6L1fxeEYifzrH62VJQ/yO73/sd9r9Qv2f1qDb+kP9n+/iHxYoWyNPtqTj
# DATA rW35a+3+IAw22qOoMxhtdtudzka/HQ277UEniINoONiM4PtG2O+Mgihsd6PNTn+z2+pF0WYritutzTXMf1wjp/GauqhnTe5TXDM3
# DATA 96xRNUX4AQYYbKicyTUDR3ew2RqMIqCGYBgFzTAa9TvRMG5uDoL+qN2CtzbDXq+z2YtGzUF3MOzEg2bc6sfDoNMH0Hpr6vYb6ldf
# DATA dVoGwmCzUwJAP45bQScI4nAYbQwHw40g2hjE0bDfbm+GrX5v2IqibtBq9VutFpayCqJ2txN0R2Ez7G9EG5ELgH3XXhkMG71BrwSI
# DATA eDAcdLtBG0bZGAw341Ev6PfDzaAdd7ohTDjqtnud4Wg4ioJwY3OjGQWb4UZnczPoDjvd1uawAERJwa8yYFoD2INlKIk2es1W3G8P
# DATA R7AonUF32I/6cb/T63a6I7xkKWoGo2YbcNbZbAEi2iPAVRy1Wp3OIB6FoQsNs5+LIV2xuQqSVq+UOjY7QBmbzU43BnIMer3hoNmN
# DATA NlodQFO7H7TC9kZnNGj3N4b9fhB1ejFgptvuA7UOBq3NMOq4kNA9dxcihFdA0t3slaGk2Wt1YPbtZnsj2NwIg07YCvpxt9/qD2BJ
# DATA eqN4c7PbB/y0h20ANezGw2YU9uPNZheWC+iqBJB8BQSb/VISicK4GQ7bm71ROArCzkbQC5sbfaCFwcaw2Rz0h61WPByFPdi2zWaw
# DATA 0dwAUg2bg8FwOBhs9sLCRgFVGUCg46LlUMBc+4MSMHrtqBeOOkB5o81BrxsNgW90BpvdKGxt9HvtURj3NoedDVifAZBs0IoB2H7Y
# DATA jNpAvu1er1kEI/vZMJiuoopuq9sugQFAGHWGw2HQ70HXzU3A/qjdHcDgreao2x1t9MJ4EAyag83N0Wg03Aw225uDje5GB1as2e63
# DATA XRjo9r0RaDk3YEevwkaz3WqWQDKMWuEmLPNgoxdHvaC3Odjc6G90hhsw7EYIf4B8WyHQyEYwGsAGCuNOq9kKIyBXkIC9zRJIcrC6
# DATA VkHRKd+vQ5j0xkYASwb0Pwj7MOtB3G8Oe512J96E3zu9jSGw0HZrCAgNNwJYtl6v22uH3Qj21mAFFBchMLNxerkCGqC0zVJKbfWH
# DATA o81Rrxc3gygeAt4HGxtD4JtRJ2wG/WF3M271esBDhlETSHUz3ugPus1+0BsOW2EQtwokQgr/hSRlJvPbVfu22ytjINFm1ALGELbg
# DATA f7A/u7A1u3GvG4zifm/Q7MUgzCKg5FYvHkRhFLVbG/Fmt9na6AzarXgzKsCiTONyEDba7VbZlmkDa2gPNzeBW8UgQWK88w34etDf
# DATA iFubm9FoMOwH3bg1iDojWKkmMP/NsDMAtr+5QVfCuTBw9dILkuercNEqoxLYDd0esLHNMOx1YiBbYO2tZrzRAuLpNLvdcNgLQRdo
# DATA 93ujZtxubow6GzHw9U44wJvoirzUNrtWCbsurG4pU2+jkI1h4DDod8Kg3QGa7UYBsMpBP4o3e7Bv+yDfu/1usNkBYdcHzhe3owhe
# DATA Clu91YBcmHssV6AGmEIZyW42W0EzDjY2WsGw2221N4DbtqJeC37Y7A3DFmAESHS4AfylBXpTOGr2wz6oIG3g70jF94AUpWhir+L1
# DATA sEXLdlB3s9kDdMTDEOi3H4EYbreCUQcYSQibuA9o2+w3+wAdSOp+CxgfQh13W4N2E/bRPUtlChiu4rntjc1uGUgByJ02qPGjcNCF
# DATA bdLtwfbo9vGuQ8AdyGfgQcEmLBhQMahSg3YnGAUgQ2AOwaDVvw+k2T3CsNNrNcv29QbQZbfTCYHVB71uE9aj2RuBpOvgXgZdIopR
# DATA CYg7oMOCxtDpgJo0bPY2QtBS4K12ywVnPl4pjLsb/TK20tocAFGAvAXZOmy1e0A2YRh2AA0glgbNcLQBGiQQyKgbteMANn8ELWHP
# DATA h8N+c9Ap0MtidHNxuQiyaBWnBXIoU9NGIF9Rfe+FsImC1gjmF4Em22+FLVCURiNYq40IeEncBs0dxA6woB5grAX7qtcs6iTsJFqH
# DATA tVitE/RAAy9TjjbDYNiJejBWCGQStYIecIz2qNfeDIB5dPoBYKU9BMJpgmLQAQqOQVUbRC0QkrBSisF5Aswa3+yExEhfr/niXaLC
# DATA RrsBOvmad+d97w//Psj+Nwr4v8H9333Qzor2P6gif7D//23r/36GtSKCqa8OXWSS8Cblf7F0UDKZLEjjqPvpaEQ10pie/DDFewTv
# DATA q/vL13Oqb3GWTVP15fJnyUx9xotuxslQfU3S37048NVinox1feAgQz+F/hpPZvZ3LhmM+QnHO7uneOtFmcOs4j0/OjrdO8bkjMo3
# DATA 0+/7x3svDnd2X52cXnyxd/By7/jk4svWN9Bs7/AZtfm+D58uVrXaOdz94uiYbjQnVy2eEMuGa9VPJ7U/55YXn706fHawd3HyxQ6w
# DATA 2e2KfQtI5QdrNe/5/sHeCaajVIobvMJ5nqKq4jfbLVF0mpf95qgJ9uXFFWOx4TvakKXbI8fqU0GW6JaW7a1c+Lbl5QxU0HOXIJxZ
# DATA I6/WAZeeanWM0FLiKMHfHeuYJmRJaL7Tcsko0RMSA875bplS+Lv4yfCj9lhVat6LnZ9cHO98haXl+24RDXqECw7P2oVHhZNlURUX
# DATA W9U1xMrcURwCHFWnIoZEhui5uuJkyJeb1InAdZk6ua3E6lTelW3bkCO+1AAzqtVlufK+SO+L17G6bXnLW1mUrkK1ptR/qp9urVun
# DATA H/D7WWP93P6p9nHt04qKkd57xkHuLxDmJVDp4kyYr3+BNyTE6joPSdTEsM+cro6sVtbVIRrKvRglfERsvpjB5sUa4xhawQivlF7E
# DATA ekRJDujAeo5cOaba4jpFNe++6gPq7KaBRpXubFR01846Mgx4J03CR8cy+xW89RdxPUzTcdV0Cr9aM9GlsoFUaNMJOlkibNsExo/V
# DATA KvIODTGlqco8sub/yG/dtxjP9M18shyjNJ3HmTmjJLwWi45MnTAbfa1Le1/Ok8tUZfBi2UNu24inEWfvAFt+MMd439zOVAahWigS
# DATA h8lUHp5treOpHuz/nEHC52UllBGsKj60s4pQZDzbOd3xK1JB0d4Y+HB3Z/eLPd+WA7RB1PdO+472AvZbqz3mZP2rafxmxveGOLP0
# DATA 5aoisx44LxZZulIOEwFlFt671i/kQkajY8hYwTQEBcLlR7ycGV4ePqsyG/I/YX4k9KkgdmhU3i5AaJFy7awpS1IdrlXWametc80W
# DATA qTiUZnc6oeWeAUCgQDflYnqN4G1WgDv3u/gZhqvbu8rUSQ5U9ZRJ8CaZLCbbiskbDvlgwc3i0fJl/H/B2KbTDlgxDHNSFuMgo5oO
# DATA 5oy/degcqZEHSGew7hUgvpof5NgsDiZmLLoCb1t+plMIVZkJ9NlyaIeEA3AFef4IeKnW2TxN/TFm2rhUUpR1+roFrpNRzQLrkgUc
# DATA Hn+A0TvtQX/jMbiSjpbGlxlb59ywZ33cORYxiXvibYWtWLpDW4RNHav4mzBcRdfquKPrSuHVM/XW+YP76tU0X8xmlI2qdpSCu1L7
# DATA 15ewDJ2ayfm3l7XlUDnarRrNQdYHDclCiy4cd6u9cMeMdadkj1V6ip6qylOy33BtSeHWpwq5JIo62infkMbuB7MoV9iKqtQ8N1VO
# DATA qQB8Kmcpbawcibh65oTo+jmsMfw0u/1L0PBrfylK51+yxvkNqJw1OTr6CHHoYBeBopo5S7LWwiIXq9BIRJSR2iKbQ+8Aci7xDniY
# DATA LrAHUz3mQ+FWObMu3JicVOWOGRbMyc7l3OFcwdX0f+g7jZAOFMP+QDiwUJ7ZDfli4g7v6IBMAKpuB1KYWAmP4GNMW6u4KG4FSxZx
# DATA pXhJKAO2VpeyZFI20ZGDb3H1t1iE0el5XZ2JT+voImd0tlwO8LwtN3vksjFJe1yu0mOfAXI4vN7Gd8rSkPvqqqIk0iTsykXCvp1e
# DATA dMVftlpIUmCdIlfNIP7MLYoKAjUv41f38wHX4YJ4chiCH6VcRA33QcURMcJqPtrWAkdj4v7zzMvaHl8svoL1OD0vsyB9+aUtjqk1
# DATA H1mpLdWbl/svEXKX3i3kLrUprxS1muTV1YwTvK8UcGdddLqC+PV1e0tkA+zLnOeQqd9DZKZ4tH6pJPl2qQPcRNYrsAmUL6rOGkut
# DATA bm9QqymNXisWx5BSiAaGFfXPzJFuWUncox9/LDNXMGzhGHfLy6/PIbqgO8fvJGWa0+tpsasWrai1rhXbqypwfQRVtP7JMI6igtZv
# DATA KdUFu1HOjBdsx2IFvnuMyDror2Aj2BadGMM4aEQOvgrfc4nm1tlg67zEIHSMQNoGq00+RzlSw4hyIV+R+fdXFVddLXQU7kqkz88S
# DATA OYnPntrGsN8Vq0iGrGtytfJ1yT5AB27jc/gPHl+mfZ8Of7qdpI3PcJ33j6rcd63UcgCSKhgOyvVVNBxEc3+EzNtzp5kviT2lAsqZ
# DATA ZZqFuIbZ0CmZBA7Ppwu2K9kWm0GSgW1gmSCGyRWkKg4CFcuP1SU2KA9IV+w8xNVOYQ4grm6Li5gXHBHcKYlI7r7U5cDPwGyUSr/6
# DATA xYaU7tVeRvNEiV7GHtYYeVIx4zR05ZFvvin+/DgPBF4zvkSigsdK8aQLChdrhHML5fEb8tXTzLhJjSlL3dBxc6HNum3RqmbprKr4
# DATA XG0Vd9evOWxeXdW0/FyrVNMozspkShiAkLKr4T0kUtLFfLagcwOGMGsP0DC/o0j3ZgXllsoAOeH4kCgoerWmo5QPGhEwp0G2D79U
# DATA l/U5bEj0VuePCKH6iBELf9vRFuo+CIJuF/6UHcvB7H5acny/biPIlS4W39acjn+rEiNDqyyL87zKeMMNTCo3VlQgqLabuqK2CA0W
# DATA FLpqGy7qQ/bZg6476uVDrRp6yS/YYwLmJxyJYs8hFUTBxg2ZunJ9aRdb8U0RcUZM4Y28jMqzBOj7zRb9F7l2s3muumH7hR7gEahg
# DATA ehmjd9yWZHV8wa0naUlz6EhBgUE0padx/XKOcomdQu3tvbTKW60d1cq0M7cs6IIV2kP5RH9qoAOBC2yw/lLT7IRid2L/OG9XSjQ4
# DATA RSYFA0a7U1Df1T19uXd8sn90qAbmyh4N9ok+xtUnvUohMY5mqN9KzAotFwtGnWXNfZAJ52KC7w56jBH3GFZou4ntp4pE8GZtqrSh
# DATA zjM5VUBXLLBDOESGpqyKs+rfNabI4SSIkfV7LJnY9q52RWJCjfFGbqlOi27JrZWmrlvzWBcaFny8rSx1oJm42HpbDm+/u1cAOa6v
# DATA 2t2dtfGq1m0POMk6vYMhRnWvE7Kf6Xy7rS91VzxPyiEvuQDU+j/SxW+5C3TP2ttv2SR8atsygKxn97OOmvMawaluhKTWaouwv0Bk
# DATA xwWzRZZiymdjeJX4FlbwJ0XelrGpOtdoeoT5SzeycZmjrGqgsu54ozjzN2+aTY50mTYr6gA9UgSak2rq4iTdL5vA91z9JZoS2Me9
# DATA npzuUwau6QYQZ62791BhnKUT4KZxWUhnZf3FR6PhMp7G6rIbr3Dr6rLPQR+kvtfdoMpPup4GdQZQn/uzDwOWnAHkElwvQcWKs2su
# DATA tBUFmBESWUA3fKkU51PiSA679FauuqF6mIXeJEkJd9hTX3IY6AoGgBd0XViqERXRnJscJkMijZLyRcW1rto+wfvrx4m+t5oUYsw1
# DATA CojDUDkwlYSElImfMSw/St5sVxpi4K1jFCTJtq0NVFtNWb+jM0fXHDdwijxymJDi2495Tztxul23vW5qqv2rLXdv6YQ012fvVQ/l
# DATA RTuENoU00e6J8UPpTc30pEGZacpp9Ja+Nfb2frJ/AltCvoEI33vx8vTru3tKrCw9+b6/M6W7lqzgN17fNFsMx0l+RdsgR1lv9oC6
# DATA X/QqyUu6m2VpCFYKHsan8iFz2DLxApgCX+nnq+CSSuzA4g+Splc2+9+FGd3PkIBS1HH3Et7E9VAI92UXRP/rsqrS+hg4eU2Hqwsk
# DATA OM2KaDJP5PYKc4/KRzYnsX5XyNVvIj07lWXM9n80zsWHorx7QBrIQiXTrqQSDCdHNrLJPIutzWT7GlzVY6UnQ4iENrzzuuPBtdOU
# DATA 6AUdrgfTsvZ7KTyQzhSt2aUD0DqgemoYI6jUtd71QMGAYg2DexsTlh7dWoK/j26ONPVh8PCCLDd/oLSBqmagEUnVIgiBhizJ2tJ1
# DATA B0SNHpe/yji33nWM+aVO7IIHXLJAab3UVNKELANNVz1gfZW/WBoxg8Rqce3hQhhMm/+LnDEopt5+9/n/rVavPVjK/2/1/5D//138
# DATA W1tbO46xQpWfL2Z0YU0cWZWROYdbalkH6BTAhNAIGoeobIwWY/tu2nvS/Sld/wOS9BdD0Wf0L7f6I/pcPe947+XRyf7p0fE+Zbrz
# DATA gSQpAYP+hsurMGsk6ZNxOp+DSf/EXGCry8Qs/VS8tml1H8uVZZz+Sh4X+x6noIGVQVV8UHKLC3fGZW7un6uqhLP8S3EY+h16vvP4
# DATA xkVCqoXPq/l8lm89eXIJushiiF5xPdxxYRJ3zmQNmI/qguG48/Zf7HyO9QcL5yDEj7R11lzfDNZHnPxT857t7Tw72D/EHHiK4apA
# DATA yyzNE6qmpG9NMNl/lT+uONfKLUWDzWXXki/9xxUK/qpC6MVWmTTb0s0UGLDDgvEFluSu8pbCdPJ0ThkXyze96BI+1r1G9BqCy+9b
# DATA 4QSdpo1RIHzIBSP3I76psRh3UHi1og+mC1JDrR757gKG84GbcJwbV6sWIMewCKfBZW4qiH6y9PwZWdOmibd8j6L1xiOvZ0izSwp8
# DATA mWslGtyJXGRp1R6+Qe/pGUxBirWN3PsGudijTUtUo85mQWd6EZcKsqKvXS5vcLpwlHvejjwDc+ejbEWr89q5vaAAeLHY8uUlFX2T
# DATA kRJ2SheBt2ZJB7l4M5h7Fu8K/hSSEWg6oFlKVhOORFcGW7Pyg3GeMrWTBZqLSwx+T4I8zhuFXneuU7AHg/w19vyMig+i54Y7wLNn
# DATA 9B505P8UM5T59wg7jscjt7PyFSydGyfQu/iQpyXYOy8prqUqWFobB1Pr8SRMEs4bKObQ3YxXPtdqtmdsrGN/irK2VtwAWrr2Zbd+
# DATA roTnzHw5d6Np/JI6wkNor36MSnCdxPQFq8KF3D7UevnWh04T4dQM17mVXP+6TlK6MUlhuhgnqFqX4KiufrjtN4uO3FMubalcBsT0
# DATA RDsFTSOIKIkGlHvQ3iNzlww5PrYtraGRLabVMyloiUX6cHrndU4BE6duGMzmeAG0TJd/xEiJ+sigbE9A3e806wbwmpOFokbM5xG0
# DATA pjyc7uMTcYTqYUlgjeEZOqjiKNdzHieTZO7mZloZ5sWxASRrBXlJ3Day6kPk+2Abce6ounmP79viS0ad0Kw048ismc5tEo8jPgqF
# DATA txHAm1v8Psd8ZSysRXjBUkuZ9AmVrxfSq6g6iwEXVtSFzJ0UKbXULIuWLp+7zNIF3Z+gZgZD2Ff+qRf13dkyNpiOmPdYvEDm7dsG
# DATA 0d4dJhZ/TJ274Dgront3LzysWqUXucanlNV9HcczAQ4vPwBmqvYN/WbpMsVNhJhtN5dw4aBYEac1pGVbS0Jj7h5VIL+z9YITN7wv
# DATA k1v3xwzwwfyEl3IfgVVVXXWBnCRhH6F9W2xx5Tj1U5Udt9OhNSyrL/F175G209BRSJepRnhQj/WpiWj5lZp1gbrm5AgAruvWg5BH
# DATA BbA1KaoBDE3q3l3OTOl2ZccNS2TQUu/j8t2mKp3OgXOGhb3nMjxrSDrMhzb7fSxO56mJMYlzH6aLKVmajidSGjh6b8nGNsNbWjAf
# DATA Nsb75kAQ3oNS3swr8al0jG3JKRo5+nDd0QmnH6zYK79xcVf/aFtv+q2ykpzHWmYKioDx4OaJtlYLR/bEboPdjKw/zjLX2zuEdq/v
# DATA DUe6ZkAJF3/wEvTv+1q8jeB9RNk6RiTYlonicYw27VPgKT4V4a0rdjgDIqTUQald7+p6S6ubTagOr16aWkFn4yX9ZNtvPS5IaekR
# DATA J/pjWdhSlofVFLMmMuswXYz5+jx0wo9vlWKbzFctDvc3quziogLIbwX2O9s7o01lIYanunow3ZquGGyBUiq1b+Na/+AivLZJ9CEF
# DATA fVn2YFyTr2LaVpbrivbIaq3yvKwAW68rG/IBX7aS1G5ZXHEJq7va6AvJ7P/1nMO6SMPvcYwH6r+0B62O6/9tDnqDP9R//a78v19K
# DATA VFXnAwrnkIu82Okqtj8qLGChM4O7z99bqNtyr/u37r8EO+wlmNxvVniDLd+v1Gux60/wQWdSW+UsF3sdtotlKKzEaL53jTTd+w8y
# DATA U2LS1WL6mnxvc+CJ42AyjIIt54iCZe3VsEZGMULLEClFkPpzjxzx85IKGSrkzaGqeXAJ/CgH20cpP3J5M83HRMmsdHZLy6cGT1Rh
# DATA Fr4MZFnRH8Pilr6n+eM6OylWd2Fls8rVmpxkyBUB6ASB81goj5/DHO9TJ9/9l3e/5NreqpD3P8Cf377/+fu/fvfPQpnr737z7u/x
# DATA Cvt3/4SFwHUlD4E/tw76Fa6glss/7TN15pmcT31Emfm7B2dAtcZlBlR6HAuQ/+aBGVDiNGmnb4OzCqV1n2/5ARFpgATKpMFz4s/m
# DATA IqFAloKu4OSbhBYzXGBQDsxVfZYQlJzoqYW45fSgWYKON6SZM8aHe085jsI/kzNCcOf4MDlgS7Dp0+B0oUwytbOg08xuiTc6JHOr
# DATA ofzw4FnAd/+XwivXcyes/+b93xBJYSV3+ITl39//DdWEf/+f4PE/Uvn5f4aX/oWPDJYU0BdisUCkYwhoCQBzU3fKMgEFk6jfRcIJ
# DATA sgl8uHsQ5v+Ched/g0T+7u+BahCW33BZfCxLD5RiFabHevfv/hmm8nP4/rcr4SWSAQjrJrJAsJ8V4D4vzwiT685GVmDprR7lbv0t
# DATA bOK7dbBHFm/W32KHdw3g3I3Ln1UK6Vgz5cIY3RPEsnreestQ6sJ/52owHqayZMWYsAFdnEdLoE4mWQ/ZmHDO9z4my9LmRrAQsAy/
# DATA evcv7/+uZBf/olIrO3e14s71R6LjjyUaVuGr2Ysn4s309IWb7MD40Kkxo/3Fu3+EL798/9c+/sEPQGYwu3t51uOPvbgQmyoAeFta
# DATA eQUAFQtc2Ql9VJGwD541bKm/82mv/ZomyrdD8M8w95+/+xf4v188Yq2JFdPlLsS/CTZOyVSyxliUmOpJ+6EkWvqWefrZmolfwAZ4
# DATA IuIz/x/svW13HMl1JqjP+BVJao6zkl1VAPjWUpFFDZpEd8MiAQ4AqrsFwjWJqgRQYqGqVFlFEIJwjmzZ6/GxduyZ3Q+ze87srM/u
# DATA 1z1Hbkt2W1JL5+wvIP/C/JKN+xIRNyIjswogu+VZS+NpojIj4z3uvXFfnrvcG50OgaIv45FYLhwG/Jxm5mAyOlVXoo7+pDObDJic
# DATA UhfeM6dEfEXSCZXTsw8EBue5LCB7MUKMHPEXTIh/8vof1d//6fWXkZrhX2L6kV9gFhDYib95/UX0UX/68ezAD+Au11OKMVCMKyJy
# DATA JRLBAYvs0WtEcNBgajdu3LrSeeHNAAP4ScUmYRFQCyQ6XEWtaXdaFPuchD5A8pKWL/FVyIxLIr+VcWqt4EeBUf43ZIi/4EWinCqc
# DATA AyVSC0VnRJ2ZCGtV9DCiWt1QCt3dPSl67ftGVGJN7RLOtAe/OQUuHzBI+FYryEN7Whbax7FryQmEE964yBr2nfU4v3EDXzpRMdwR
# DATA I5VgBlYUPMw7LYh48TCy76owsd4YDl1L77zgkYQmcEu23A2qgS3QosXZoWr0D1NA3hgDNI1TbkX1UotP1RZ0E7oovnFGQCgMNHnO
# DATA i33OD2o+G+VMLlAaiCv31t8WRRhFX+WZcWgFyWaqOEhxsB8p5c9PBTYZjmqOO4AjdfKYHLlzoVpA71aopiiVBkb9n7HXf6oG8jcg
# DATA Pij5rih6qkefK7LyU+RDX3hTAuKr+urNX4qjCA+dqxHSGwO72D8863CcLAONyT3TD1ytxagWQTHZ+XitoQqF6J4QvD9XK0mkXRH5
# DATA uCxwmToYT1pKfnzHYfZovUCfi9lJ7YRi3U1mVlHuW2W8oHwXv/48OHg1blir/4ByxW8iyLQFJFM9+O3rfxZyA9Co3LFzLhjQz6K5
# DATA o1Opicj4IqsER/N+3kkP8tFgNmVn9LjZRPcofAtAl3lJLL/moTUDIYBhAQInQIMKLC6AqQsNCpFqd6j5YvHzd7j9fxYFJ/aXcXBc
# DATA egT5Qk0Db/scmBjkH1NH6a8gAxodp0s1ji2CztqLcQf7HDlRhKAJYqOT8PK0sjijvx5Niru88LGGbQj6IZTPvCIaTkVzhFtd1jEn
# DATA 17ijxXOnSxf1QDmAMPruYqrQHpMcup7t71/i8CGBMXIKUMNfAHN4/Q9w0AQFNTT3S7jR4LHUIkzphYYYHFLHMpwJMTCbTruwprKi
# DATA 4LqW1HP15eX7zJ+rUf8DMdg3/5P6+4s5K20hnUSXJYqGdqoUtwJP/apDxKSaU3AVfVebv8b/BZYV7mRqWf+cNDN0aK/AbXBsUoYS
# DATA ek8bokzM0WWfbFOu8b9g75U89JvRw4GS2PpdawQFDXaOLnTUFjPZe9YZoueUMjI9q4dJ1B0MRqekA/Qnrq6n0tz2941PKruuru5f
# DATA OLZ83Xd7Is0j3HDorcAXBW55AXcmzMr4D3ja/glOV9nR04IaeEK0nZaXCuty7ovQ5E6x5gifSkoY5ebdVs4SOh4a/VSfoYvwsubp
# DATA y6xXI+W+u6LXr19/CD3CtVHnfJYOkNL3+J7CXvJDbduYHqegseDoNnJctNQVjCcuTzDgU5zr1eIRFWUBPP7aSaEc6kUPg1GKflyB
# DATA 9WKlisLrP0gVxn0Kpv29toRGqpQ6NEoX/kA/DytwEgH/1lsqGWw+Unnq/hFzoYJGUh25BRRUZQLLZQCiSllRqX8ImInEioOtwJVi
# DATA ivXY02LFjQqYJz9xvNuixf2OWWqKOFaatuZe6yYqCWrxwWB0QIkQ6OpT4gFDDHJB2ClvJi7LONvzGKcrqxTAsbjSpbCACZtWi3GG
# DATA NfCDS4tqvxcxzRdY6P7uD4GZgbVbmhh5cmuuHES5HHKZozhHQLmEcPL1ZvAm3xsnilZrHvGkoAKTtIqE2Ob44cXIZ99leO00Par2
# DATA GTIG0cXqszr2+PeRi9xVt1WV1H5wiw0LVZ2LFta+oVdNg64Dful70jYHNonQONMiuf4HVAWZtoN+yVrNK5aM8P8gdNg8K+Rj517B
# DATA UTGdaoXBUfwU6gWlejgZOzn0CUQiVutXVOfnaOffcjtoh1y3Pa0s9ydOqycD8xZy+/RnRp/eInPx1Ij4IewuQ5EKvNevm2hAac0s
# DATA ipOTZH/YPJgBaktJ9XlWWo++qfkzY66wemIKVYfy2WsIm7oENCTv0BJAEWav2CaeqGJPaaMAKhJ+n8zx3iVmtHOWqxvN+it1v1u9
# DATA os+hk83o9+H/p8TF9295/n+rK7f/kP/9a/P/252kw5wOpbrQUg4sxcgg/ifnGAfQJmQTdYO1wd6KToHkPJpNqSziiqgi4DOeDvLF
# DATA U791R+Ozt0/q1j9SnTe/pul08UhyneptMgCRm5Bn3GfgxgyWWewPP8MRRbYcqlnq8NdsiH+7KeTgIFNelqFilFMIrILDjrfoDurS
# DATA lKxl0WAYNkaRaj1UStkmRuVlOwPSg3+YsQ14AsO52yIz/SeKBuhYBcW9YXWULNkF5VX0xJAHknktHbQ6kbWo10+PhiMlWHdJ56Fk
# DATA Z4SdmY6i/Hh0ajYKEjncKCjNzrgnFECGO4Zt3+pjsjzhq3o0GtPudGISGcARp5ByfMm7jE6C46of6Ju2df9sUqYh87ISZc6fjUW0
# DATA CuAt8qfsPfLPYMhzU53okVE2hLnJe4o9+L/VZeGfQcNWaAhNgOCm4rq1BdP66HRCGu7Ixiy7/THTBEcMESU7BT3GzbfrdaV9zNpH
# DATA wa2C9Nlf+m4X6jr2+neucwX02UDFqhvYtJMigIX0GuYDYfLyyU1mk/d1YHPWrPtwPbKxDYxzLCaIXDPUxwhpnk6bO52NJ1uP1muE
# DATA dDztwDvrMwsF/yhaGSm2WA5ND05t/LUiLXDzHuHdNlO/Ftkx/zveUn+u5lFdSene+Sv0sfkt6JB+B/ZlWBZ1Df21mtnCnfw3b35K
# DATA 9ne4ff8T+SGiwf7Xb/5j7AJBdniu+arKs+04WcTwKG7Z/QhwoBQL0ooI/jlGvSr/jH4M07O6igkaX6q7Fqh1eTbUA7xiEtyEfqp+
# DATA +0lAwv1qWV2qmtC8q45AnzuFct1wCvHgHkD2DHQqwlU2U09Q21vj8mEobM4qAHvkcARqdU10ciZxBfkRG3IViLyfdh5vftfdT0Z3
# DATA aopsr39ULGLePtrYrni7s/XQq79U47o4gYRth1Tp57DpfiW3JNnIxaYMOxJW9I+ol3xEp+r998nAUXp4LjGwv1P7nZQ7f49D+mX0
# DATA 5s+JqIFLbvWA1HFC7+9/ZP9dPRHwkaJ0aG8GBdKvwINXPSKXt5po4O6KEiC8Vr6IIH+HcfJIx+PBWceldvQPxGXhRd5hp/qSgkVa
# DATA JXlDUI4YgQ5plJOlgcrv0Tner8Pzrc72o63Nx5+ps4q/1PZaf7i7tW0ebG59uPX48dYnDKYqL6F8PlSxQzwdtk3Hylhzzrw46qiJ
# DATA NJ1iErFfj/QTog77zg4vEmRt8TIVMUkSFRFRCqeZuizN/YK8BNHV59fsbgC7Aggw+zoB6aXiQoZw3GpxRcPaiwK9C80qTDlh89m3
# DATA drh6AgjBAdsij35/PpaCuIqq8u5ASZdOyxzDY64U7K8oNB8g0Hb6PQniXoguKOrVxG4iwyKlAybVS9bjZrhuZyZttDe0kQ7Rnctb
# DATA YcbQYHhmbWldRn0fWRHqWlon80RV0YRSKtloCheU3HxSGGQOcNA1HgMA0AZ8RhyJLjgKcqxyestM2OuV6nCoW2IkS4Wq1atC3eqZ
# DATA rNxZTH3mPNXpAhLNf1YU8u9RAkTXQd02fK4FxuIuSaR8Z28c/hhxnm0n7UyzHRaiaWBqCnNoQoigBG2q2VBjvfZiQ4EyLwKJjCnm
# DATA 5yLynBLKkEp8SdaISDEmsCH8mhyordkEuQq67v8DOhiiLyGK3hhLUhSZ69TDOjjD8l8xoDST3IVP9mLQF+zwQ+OWypjLnWN1LdS3
# DATA OBNPC6TC5TrCU5sLq7lPCjIwvsOH6p4NuBd876aP0IrWWqYcNPSEgo60Jz1cfNyboqqgCV1E+6OadupiRbv8zUzNgrZSw++xuiyf
# DATA jiY981vdJOav3N/aeIo/lcoT19SFjONLWFElDvwZecATg/gJcoTfRLiQShDhuCUQ1d/8JZqc/rn8AmpAxqzKolaDvmOsnl6mOg8P
# DATA 9gL89cNZBkiv8OfhJD06sWlUHHChsqVgvCKNk6YKsFeKxorBAMlONnxZA5UsJ++WADUvsjN+aqoORaWlU9V5iEybxH9S+04rewUr
# DATA shc9n+6/l3wH9oENtVE1cvQMvL7Rbt74N7Eko5AuOwMld41rJZQgkKKaTzy6Ci8IsA6SBJjyFDIadVrQfaAhbbMVdWWHg/Qob2OV
# DATA FfYErh/+0ZmQdSJkzK7yXrEBfuVA7arPecLHk9GrM1J/Uz+cQ1qPXvSHvXbcTXu9s9jqXczc1r5z/5pIK9ps7Cfu5FJ1NL+17xTK
# DATA soUTdI3g0YTyKMuahobU/ATuw9EQ0dL0h0suGhZIELOhXYZhaB14eLwEZvI3pFOY7pX+Cx3boeYHIuGQi6nFWwZmjUIfj/pDx+dd
# DATA HzreITApJ8mf1J7nNxD9foLm2+f5e0lt70/uqb1au5cUoCOFNwSNh5MZ4j/qLOEC0NTRo5uIuUd/39qnHReyIClRDLnhinBYHUpA
# DATA Fj+3Oe5DgRQDIAngU0F4D0XAQLLHU6Y7IgHfdBAVxanjvqjO4G0uPo8pEpUqgUf8t67pXNdUzIbjBlcBvschBVnJntD3AYeTIfJ3
# DATA nlCqAs/bOerRsCo31ht7/p7xsGjipoEGkqjhP7zwLrc4jxrPDbO1F/eOzC6YO9pE3qnzOc/fAVOB2yVwiF+gAPFLkBVQSPgSr5m/
# DATA oCefgzTxO/RV+FxJFH+jnv4Gmc4kgxiJjCjIPXmJwYsMXGIoVAMVSubNm7+Oy8HoTLpNANSpR0ItU5DTiCUZxbBVwgEBbFt9kjmS
# DATA 6jFLmFC5yS1USFleyO9TVI4iKzP6OOyerHJPtbWP6KlGk1XILIa5wHWaeWwCmy8koIK/ys8/xxadkMbLU8wavcf7779f3gACsV/I
# DATA FVG915k1e30dAWLWg6lHS851YNWWwrNi7onMxHRDw5cIOwb2cRQk6zYbh02EN2MfSCxBUjN8yGG9CBxaJVMWIcpMnXv0lwPrumf3
# DATA Gmp7bYfgRoAfaK2HByvGTIVwxXCSiYMR7KYnu2jJR5tEUPjpT0ZDvBHTjKp7w5SycecBiagkzIHnCQQ89bmZ+D0twMOSoC+Y0L1o
# DATA YseXGW0Skj3yp1+/iIVbAS4lajkLy0p9AXkNumKz8uy7IS6LSXniaAM4B3WfdZ/YbiBrAxbSJ9TK9d61OfDlN6Pd40xx3Hwa6V0H
# DATA pymdTY9Hk746df2XGQceDrNT6NQ9FmcpmxDZvcYAyDodjYo5Nw61eao/LOsCalIm/SPEX227xwsXRGjRTWAfrXtd0DXfCyQwfmC8
# DATA 2Im9xuo+AaZqIbhMoCbB00jRqkXd1aCk7DhvBOmMuAvYms5VMy1atwsXmNAuf/kWleTP7Q5/s+eU30endKhWH1KwCWCvgKAzfqB5
# DATA 6OZBF+ijMR8kAtlTDPMHatc3MAjVakj4MQqADBXIj9Th8IJJbSX2BNXZvV2cKWjuMK5zsi3dS01xwNcLjiNPOg0G7/Q8EBhj1HYM
# DATA w9ixRDipu/5GbEyuQVE9VvY3i2/E1hVfgw32lSw0GY8G7A2Gz9QCNNAOPmP3QgeYU+petFd8APVwjxOEa7VEPbohdC2gGu930fjM
# DATA +Cjue3Tc3dFkEgvse20i6SySX+kATmOV9HbfqIwQDc+491dQcQ3tppWY2pUJopNxwYQ+Bj4VcAK6nT3t8XswGg1qEiuO/6ZB70xp
# DATA FQzh4IRberZhq6BQg8S7Fenm8bMWunEoeSYbwx812kbSlqdDk401z/2AXvv7fMJdaJnB2AHnPOL8Qsga0EkghixAw0+L1ampK+0N
# DATA 3tYf+mKgJ80g7y+cLJABrJyz8CdMEhrcdvPsZBAX+1erqADTPjanr+AwkBEax42Osn6JpJBztsLDITCOgrUWptPoDTJwUSmq7LU2
# DATA zVXe18EdpXOSKV6pH4A1HWVU+RuYCv/uDxEkVD4iZzXFKSbZaToYyFumUeJZ6YU8mWr6jc3JdzbG8DxZleEMcEaAh9QoE6pTiG+d
# DATA WhV8rb24hvr/UPetX4GF/M1fsp3nl869ytyZTFtwK0O9nSoFqjwXWwGM83TDgjj4v7Y+JXaaHVEfDaKBrmOuKvuJUcGDxhTIrZZc
# DATA kHYPRrPe4SBFmMb4qAvnOlnQR+YXhF6EykwAyDGoV79FW9jfR7uPd0oGpfb/aNIzmmg26SxgNbIaeL3TFp4S+4WZEYCcz6dZioYJ
# DATA EPR76UB9+XYz8BNysAAV7p/CpRtu5f74tfeI6ZJrN4A+76h3T7SbuelnEraX0SBh9AsOcLHxwfX/c1ZXf1k1us+LKumfv/kLf9So
# DATA ssezL040/KwZOmGWln74F9vAHD2lhFq3b99invZqkp4FG5HEh4RL+XtOUxtUmFv7lm1u3lqgOdPOPL6AQJxzdwLI7JKO+9gCCC92
# DATA tup2TBdoSLo1f/n+G5kS3vx1tPZ0o+4sFsBOMA7Fz6NPVc0F1wWLPMGuC7yA+XE6Ie3pHGstO2uELK9IiB15JmAsg1rJYog1iVIi
# DATA 5ytGS/kM1S+vxW1R2krglprgwAo2ZiuQ2QG00DeM5JPRACajZixWjlHKjp6YFuNVWdPUAlZv40EYnMolz1fems7EBMhKn00QKHwv
# DATA VmPfW9m/XF8KrclZhrV6RMMs1sUrSXY7OB5cMnG9JtVkusy4Yk6qBiiIGy2QOy17xS/2ncmo7pThKfPP4H+xeC9hpWyl5bYZvf47
# DATA pKp/iT4mPwfz4C+xOAXLkVlcWxUBL/BL/JSeM1f6OT/8lQHQoSnx5Cn1EPWV8JKWKdazYIWwtpkNVyAxnNfhyaFAu+IU/T8YW/dn
# DATA cmrIAwvRcqxLIllBBSk6SLsvZmPhv0APyIWCT1zDgUmck9GXvufE0To3NHhkySTSVgWKtyaU0MnPEWFatVYAqVhLii+xmjr1RP0X
# DATA nBxp+7esXF2SZv0Ck3yBqGR+0mWopa6v6sf4GABWW+oPktwRE48Gwt2iH8mFQHCtkH5d9hUUsWQqBAIl71h+7XP1am7tOVI4Qk9S
# DATA 4Juk2Lb2QnWfd1oWwoX2up1TRf8wNIZrba9uL/gLr2bw8kOew9gzCxTrFBdkt2paluzwULEj0DS22fXEoaDXwlSQk00U+SuO8tx0
# DATA 2mFhemfGwVR30ulDAysIbYurYlFb0Csh0NE8bYsqy+ZmVKtX3YUfQjHS/nu2mT1GuWCdRVDTZaYyYcxorlyHFBTb1GlXXkEZ3IMN
# DATA su9WQ97SaOYJgFQvS+OlGnu7wQyqRD3qiMN0OMny45oOOjW9r/vyTL3CKuCvlQnpJpeqDtGktnux1tMdrhJHB5vfdDvwWqAKIajw
# DATA 4j20X4JVleCd+8Nmnk05H0At5kwSpM1zgS/Qpg/oE/hxK5z9HV/SCaJnceKZfbCEY/ahb0xSQPBzIceY2DTnsNBC+m3cI8sv08ny
# DATA oH9gEWCXFVONF3dV/r/M5cowTIJu/Rl5ov49hYeYOHXjc+prLNQlXUka/1Xe3kiw+CXGtkuZ5XPthKT++x8lYBTOsdbPncegjAEi
# DATA c9DH9A0xp+YjjmTPpDrt3WwCCQJVGZ7/VunUICtMex3IfK6FcAGsBsrkQf9HWa9jtsseb4LqBa22w3qDIdaCG0Ck+VvWVJc3pDPm
# DATA wn5Z2ZfDDWyni+ouBbZ31RgBiUXszX2RhRH8h8VEORUXJ9QM3T0vJbtZ0S4XERzuvNykBZ/gBwa5ASfbemqbHcTzaoIg/O908ke8
# DATA XNqXe1Qh4n3wAuoLFbIDWZKrUPcAJ8BsQV/w/+r7WGAsxF+gKvBLcNnUV4BfVTqN85G+Rx4Wv2Xsy5+RRE9+gSVz7STXenVmT8E8
# DATA +r1nqOh+sIq9mwQs4lgCzLwl3nbqaJ+OwMw6sOrhNeJ19pyMSswlaLYS0KaW02BSKbOx9+Id7oG7xR1LyRMcrAXWF1v9UQbqUkov
# DATA X7nfWeljPuRmk4IfFOHmYS/pLFwq9sa4AqMy+WfOXoHbH7AA9iENby8f/8hZOe6X9N5SPRbHhXPJGeFMTWnxbbk9ggVoLLyGcQYo
# DATA QLsxLbIuXxLp9bLeU9ig+B3wAa8EWa/UxnKFUCi9N8ciWI+E1NI/vLQAV7Jq29KtiqFhPAcsDbb8P5Mq2bu/I2glxk4WtQJfLsK6
# DATA v2A0XRfWhnR9v8A4P8BA/63VLwdGHhqw/0YLAfi5Y8qHkmyptSvo7Q2qTRsIhYTpvcB6CvcTL8iu6Gh7GbsrNu3huJd27+2NsCjF
# DATA 85bGv+y9RB9MKTjVyAm1CRbWOTcVcaGad12phdfINZ4IXUDRFllSAWoTrJefGZWTZQYIob7x4Og0PhIqTap1CVdQJXgDmBeMUQDX
# DATA VId1E3rpO0n+3JOT78HJ40AwPp1v/pNx9Qd9u1PcKPQ+R+oudXhased7bnLCHNQlfoHyhsTB1N7roZm1dt1FtSc4awEvY25FeJ7P
# DATA Xe86acNsH+LFL97cBd/FyDQk3aHJ5ahXFGLQnSF8JkhjLcgc1bHnKLrhrDo6Y8f98Dz+cHtrc7ezvvmo82jrydrGJtwipIFAjPzp
# DATA 2ub6Y1tMv7FyDaiwKRe2CMFRD71JJG9EiKOB1KnVRgAv6zi04FFjPeiivpyV6r5cg7281l5UO+/OmRLTnn3Qefrsg8cbD/VU6IbQ
# DATA A7wYX+Ki4VX5We4NySHHzMueq83CO/wQdW0o052mL7NGAN3LuGouGfyjwF4NbBxh9gjuGy6os4lJCtamkHlJ9trSOOiZJ9vGWJgU
# DATA u1EUiRyZqVQwujQn1w2OTodZz2kw5NklxTL3i3p4uZK6o6zbT8SCzAn4vPJRCh2E/aUrnJavc7ueB05Vq+JMXbhLzbuycJSfaMiZ
# DATA 0oUPlwb/4JJTgGtH1g4LHSqCUVtLb9/G/IX6KiisyypN+2WdZO8vtvvs76F5CX8luJXo+5CTGpdaKtyFNFkhT1vdA3SYZs9sEaX7
# DATA yJirBdHywA6JlAtHba7zwqQqVPuv1xG00ZiBy04oMXjzBdVDRsZ2JG1JpA000jSVgQ6ig1O1+JDOpqPY95J+e3OLrLfUYUtmtuBh
# DATA 2YLGQOc5bWHFemyLOG+hCqzUI4UbbuseX9kPqODn9bmbP+yX90pA6U0MkSc2x9a2qncrynNt/K8we7QdLbJiBOyBSP+gFAjmkLZv
# DATA HCmC+2YTSIWtaCpv8nbNoXfyMCRztq0hD5XN7Ih9lbfjOsd8lVJZS0gSa7x1TlWpn4ys5illwWOrRLGHahc+1FW2C42gmyfeYdvc
# DATA Uc9tBpuuHoOM4kXqVjYpSA39iQmR6sSrUPeRrLE3bvCnHtnCmZAePNJLuxZDGrruMViZxhmkH1e7p/9SETj8mZS6EwdMGuovxz91
# DATA YUcf3xOJvA86ZRgSIbAG+qSIX2Aq4ug387sqCM6UJINmatUaJeIAl0P9Csa+T8+47VJ+nVBkCjp4ehobin3smCG5VzgG1Kv45Ioy
# DATA wryKriYulM1e6EZWJgjIZdy3cczcy2rPb/ulf3FbYKzX2gv0PxCeS61ahzp64OrauFUPdCIQtfsC7/Ge6V80oX8kS2HA9LDMTRW7
# DATA Urfu09XE7jnBnda6GBLO5y9Gpej+zegxBtITguQs5yzfBKAS59F4dqBGFD3bfhwRTBklL+F4eIKFUTM8yfK8uZh2hOIcIKveJBtQ
# DATA UowhkwDevOQeVRrsx5/NQekpTTlQptflaj1Q4WFvrHiLpI9yR+i60Kyk9bXrTzbXPln73nqH9DRq6siZM6T/wGXRjSQOEImiDAuO
# DATA qGyr84gQu8X8fWnPHv6y2rmnWGjfU4cvdKQC1cClNDSlLRdgRs+hT1H95KrAN2ibXRJkKYSwZFieqbQEbClIYM1HRfoTpuX2g/0i
# DATA v/ZqQ0YCvk8m2p0Do2zHvgmpDDAg0AYw5ojpcJz1JzbMlIViwi14NWV8EMW5z5gO2EhWUw+YOcjnEswP5nHDAI86sVqYFJdCtZLQ
# DATA POuhnk4UTbBxjJ4Hk8xURUGIXrCmjDyWQZtz4xQJA5+DUZy+mEHGeBVh8C/42wmbChUzMEmEqM8QxVnO+0NPv4PQt8CqMu+UY0Vf
# DATA Xb2a5PptlHKUnlKduY0pCrHyu8SPJA+HPfpWPW3eMTG7JPKXG3uM/kbo6BIXboTNaCh444Qw6GoxQ1G4j2YArJH0zYOkWaephls4
# DATA v90PpfbJQ2SZN1whUBaccMcmhLWbNdQhnWQy2rWXjXPz42DWH/Q4SFhdL1CtAubgCgSYG7W9uNFjXD6eJnKBpCrR9wh1oDcoB5EL
# DATA X+pNUIHbls1WUHojJp72zqqiU3V2Y3Zt1d7FNVRCt4qAkBa/u6m6UdsDIO3sVdadTdODAQYZb8RBLG3wt6JgatxZpqXmWO28BLPq
# DATA 6nVADXljTDZCJFDQGaASkHsFvbnriBU+mk3bt1ZWWIFMuQFEB3fMn+tuEoDLeGhIGz15aMhQwOj1r6KPd3ef7jR0mM6bnwZdgGwg
# DATA 4Rcag4WAetm56B9RzQJuSL9WBxGBwvEyx3RJSXtAtiQyLruylyPdEU0iR/N9uiXDkRhkNM9QZ9ZrQLV0X2Y/9CQINsr16ZTd1od6
# DATA DYQP97PAbgq4XlsQy4WZ5IIWDMn4RFAue9ejs/Lbs8GrsbbJCW1xxWYkIYpdm4ikCoMe5gjCcfic4gMaEUUnOXis/N2ywTrAPDN5
# DATA k6Zc5yQN4JpLrqq5IVfBlSaO9kXAgrj4F4ULg3HdteZlqiAAGsTDYFQXC3aaB6AiqN7mbIguSyf9HK5NndELr7qiT4krPFA1dQEN
# DATA xGhAXicsSlBd9++EMGwpAU8A5lccHOk7lVjgX9vVuRKIG8tiz3fbPdEB8Yis6yQOMdlXu7CDStrFCUuhVRwxsKM5TYoAAOekaXe1
# DATA EvbG7ZGLTWKUbfPoQFAIcOQpDKvFU+g2IfGaeQBC5cmh7y+yM4mCe0labKFVRfCPmcdF4tc5oEyr5bUf+T+hcwlwnf/gqOa/+tNq
# DATA L/IFbC0+oBLDy4Xa4gLVqkzdwLW2TxYWdfMt5GNwcJ4xju9n85Cem5FMSq39ethLCJD4jeOeYxa58oFxZK/L0BYXeRi7wNY21AeS
# DATA DckjpH72KTYwNEFh2xmnfc0iC9YXZHP2YZ3woqiwg38zz4Lg6XtIorNJTkryOZUvu03gxDIVpZPxffI5dGsY7fkWCSWne9f/JnmR
# DATA 1JJAeke2909Zw3yup7zlrUA9knPA0RXI4cXjpClc2dUXak5lSYBJlSUuCjeJxQ+7TnlJd3cD8RWYZWezikbMvT/IFHWvUKaqGynP
# DATA JmdwGEJScu3RUHXX9IU6TACKYlNQ/GOxSAt/2LUACBfVVIgtTeZMjZW/yLAn5a66a+C/bFVvV4eRRt16Clob13HWETf3Gc9RioPl
# DATA TfsULVSSqvfkzMKIKwZBr0AOpv+v+Crit3Ym2SBThNdjVqHBaa2LNkI6MryLTtRyGX2wu4mPaHQRRJhj7ac5okUy0yrDhWMdZwha
# DATA oRTVD8Un+aGDseB+Zszv5UBxVJM/UqPw8ibWLxeslhJioQJd9rPEYlk2N6YW9JzgH1eYKvfTt5ssXdc7m67556xK3C5DlFtQGxmQ
# DATA L4wbfFv7+raCt2VGo4OwG7wB6zuxo37DjDxoRED9L1Yn/5BZSyHnq9YPL2fT7jKWWrbu81gm7aXjKeP/eY714fvhgtqG0lxVjjLU
# DATA JKzilAP4oybYk4xsNrITS1fJu5pHUi+4ygYoNo0dXOPADbSw3kVNUJzMi7fXuqJC9M/ibGNR3VKBoVmpyEh7PskNykUhkUf4ny+o
# DATA uSrU1BmkZ6MZBrA4nLzIaxY8kAV+U8ragxcSWJalxZaCxfIP1Pfr+KcixeLK6qgq3ZusSTFjaPlCOWbeEnLM5DYrA/iwR68VBO30
# DATA FiSEV+jBgBiYkAKSULKQS9G7AelBvaDXM3U3eaIvJYs4ZpKvYZ2RTZ6kY3kHmYeJmJhMb5T4FxX7RE5ai+iD+Lpolm3f84kM6Ysc
# DATA PWqruKVTJWgiNbadkRe+pEL5bVncNcPidFhzsCtOngavTp3EJzxGWlKRWsUJP3G5g3pQi5fTcX8ZwI+XCZozJls4tEH7YlmDCI0B
# DATA 8oH82kUy1SYauzr0tua9Q773sZrxgXp3roF+e1naY4RqnNqTkZqI0bDfrYHCfPUmwbWcHgMyc6HAffN5qzz9NSX/wy5RdjP00tKW
# DATA nzuYB1CxKzVzoWzTIrDNXxlXeDP+DSXCtli1grOBmuDwRwej3pmLxqt7ipqwGiTn5BydMFvl+M8edjrUKwACAm9p7+nW4PBWld6z
# DATA JXnX9vPHI3V81sDBCAw7dQySrMCLJt2LVdOgtg2UZGjZ+rnJqkPOwzo36E8h3+hvCekC4ll/h9FyvwRNXECw99aAeZBMEtwEO1yV
# DATA mogQwwkdQYm+k6yYhQpdqxRjVKUiyCkU59GzZxuPmr5cyKlY0d9K0SFqv8uhd7dXbidVZGHxzRcedG1rhxOeyzTozlSoYciswNYm
# DATA nNtQFjyS+SDLxrWbzCjDqlO0b0YcyfhbLz6Zwpi1spRX8yev/1H9/Z9ef8mmUMCdJMiSUFrcYrjkr01mCg3GT2bLtzB/XhNyznz9
# DATA +v9qw69/+eavIOjTz50Bo4sDOtoipyuXu4w19msTvPr5GDACaunkKLcZv+AX0FfO/9zWOurYUz3jZ02yR+Gfjs4Xn4BW0oYEBSrW
# DATA vYwDHTfVV1dhps2x9tAGWbAKMPw0iJkLs7W1holqaOYQas/kPpnkyEF1IvXm2uRoBtvnKb6pCfm23en0Rt1OJxFfNsEzMOVParHp
# DATA WQwODiPw+2jvacuQMQxp2HppvdemezEaTLh7ODLoWKEG1U0RwO/qiLzcfko5BxWnV2JcT5oXw99aScXprpMjsB4Saqu7pCSwhpE6
# DATA bb2Lxs5UVw6Xw8YJ9czWXYawu0Bd6JuS3Csrw/C0XKyqNnVX1xfZGLJ74p6J6QI+VUvh2e90qNdR1uijeG7xSWG3xp5hga0GTiK2
# DATA YDdAqLRBD7D70SMXy+I/UDqvJQ7FGI5cMMKad9CA5OptDPyQSEYlXjc3mREZdqbHReBGnJ4AAje3F4l9GlEjFcROd1ICJPbBH5ZB
# DATA 1fETumO6Y+DftAj8g6+e/MtGifEDg8Ygf1MwMP6WyMZFhHXMCOzNfVJO6igMTZMPSTIkKRHkQ8JCkErrsDucDhwW5tiEPXpbmpYY
# DATA NUboAkYZumqx4tiqKwlnKH64vb62q/MRbz/6ZNvPTVynzEi2GZ0Y/LCHDcgkufFpjFcDaMEVgHA0zUN4UYP/1PnJ462H3+2sf+qK
# DATA nS63DISD0i5BCb83OxnnkvDP3TRaRQHJynPwxE7zbr/fZn9KMEcNp+2bCTAgtbAddJ3rdHC/djqw3zqd2Pqh5v2j4ewEFxz+TAfN
# DATA nY2Pdte3n9Qj+/vjZ0+llxY9p39qVIFJyXejo6756NrXn9b05cQRdIgjSrmkJsVRI6N+NzsjUTQglZP4tXOmqPDJ+qv+VNhrPVy0
# DATA jCqraQHpITuw4z7nljwxLtFhc6//zoqq5jJi5NaCy0TQfW+Oyx6i9PwE86qD9Pu5BgT5FaZZ/wIh976xyP9O0smPDtRRGZ994yv7
# DATA HySsv3v7Nv6r/uf9e+vW7ffv6mf8/P337979RrTyja/hfzPwkFVNfuNf5/++eW15lk+WD/rD5Wz4MhqfKdYxvLV0/fr17SztqS2O
# DATA 20NdS9eebhBcEfov42U1j6bHk9Hs6DgUM6TKN1UtS0zWteiqf4MpBQ4WHNLeVD9Vt1W8MvJPdXM5VndM/RMIn/57lC+hfwXcPVQR
# DATA zT1AuNRFJqYxRVj0n9Cm/lveYL1nTl9d5ZR5Ouv3qA9MI3Qf8C6lCJu6ICpa2h2oAUXGhEgXPnObMhK+GjRfPU0aYNb9K0Z5MobE
# DATA Kv2eeiFznpC3BfI8jqqx/tlL0qOxOp8xhpIq0ptPe/1hs5+n0+lZregT5o4gfkJ+j5GI51HVTvrglU3i42iI6Z1Swis+0d+3Ilf4
# DATA 4y7x0jf53xoNG8kyjZyIa384nk31SzO9m6PtjLTCviYRdAn6HSsUeWgUfkFvOly8BiI6Xk4Uox6Dhh/kppP8SE2/Og5qy9chuZtq
# DATA Y+78QMOmfvXHDzD3/D04OHhcDim6BlU6ENFkB7M27tsedjr9YX/a6XDPSB85eqE2QuwAlVj9Kt0QTXgZ9NXxZ+b8zton8JwUvQY3
# DATA 4MJokmw8Gpib3JTXbsJrygpNf+qs0EEnOW+OnqlnqZ0DFLFGs6lMhV2PTN265jg8nnZbozqgpt723gx09eb7zRX1/1ZhsJhBGMrA
# DATA j1ZrNb5YpMfb2cloyrQu15dYcsinpU0jSk28s/NxNJ0NYWRwGKBELCNqBodNXEv8CxeUVtBkdV4GURVfuF/xPkRvr08bH44mp+mk
# DATA l/UaTycjcLCL7HLKt+oveGdn4ILmziZ1WGCCGC78wu3QQvp9cUBBwrTnTx47g8qAGgLQFbPzK6R/04Iq+1s7gVGYMEbMC/gkjjHC
# DATA UUQqLrPrzo0bch4vHKRRsxjuXuCye/EaJXv8EQeGg07tg0zd2CZI0+znfk5Z37cUdfWluQj5o5p/oNm9FT5GugjTQmsirgT4Nmly
# DATA 2SQ8joeUhLixy3Cq7kS9apyenmLOvYZplfCMbYvFmXWs05BwW1Fo2FYTCBKs3RKAJXBSP1rfZQPiarKAV6jaKMUdti12D8wPGKpw
# DATA 68AEtuE/hmy3Dfl2EECKan+85Yl9TbdJZAjaDHR7nh3IzXbtWmFu3dQ2GGGKKbPEAPYrV5REDyL/23kGEp94gQinewM5SNXda3KU
# DATA lTg1MVt2kjtST0Ius5eyixifKZIgggaNKsOYe5xkjd7+8moGGnf75rfr0Z2Vm/CfW/Cf2xdYTG/Y+9HNcNPSeqFoiP4gKV39QqD2
# DATA vIXBzRwdpv1B1mshx4i0s6gdRCJjtQILUQuaZerRLm3ekJGmYvJ+77OiPhlmqKTkibkHljLwEThRRbvR062dXdgV6F3nB7FB59Tt
# DATA 7mRMITXW/lDM1VzD4PFDtdGnTkI3nXK9N23qGwtC0XlV16EAPPuRar05m3ZD2pvSyvr5iBKcUmVNnWs+/j6w3vdWVlorK56DPdXV
# DATA nP4IlO/hMCXTHJfVtdI37WCHnZzszTTXJWp+6abtc2L7y11Vnf6+MKUNX2YTJYfm4C+b/3CW9kCmG01TSv4I6Bhpf0iqduNGCzc/
# DATA h8VzbkeohYzGWhwV6Ap8l5moWZ0NBghOXZvEe2uN76eNH600vt1p7J/fqt+6exFTMu25MvwzLfL2Rhkx68P+FKX3nsX5jmgevI05
# DATA ydSHGFwjcr52TtIxCih0JwIBZe3h7sb31lGzrm5e6u4EfjLxo42dtQ8erz9COax/ou6T+PjxxpONXXqavRqD+QSern/6dGObno6G
# DATA nWPKHmSrMPl87Nyxx4YBz7e9mzsjwxfD0elQ6wUiXdMSIVGcACChaqeHiZNp0dkbSXHjDhYg2LGVpO6VgM8600l6eNjv6jJyWVei
# DATA +21qAv749srK+6vf/vbNO7ffv73y7W+v6lsLlsIeBArNG93GEL08I+6F2rszuMHmZhHBn/boDGWzwMg6sHunHV2MBhEPR/Q8Tpqz
# DATA 8VjJwhYSS9dnbiibW53t9R1FfdVaPlr7DP75ZH39u/Dvk63N3Y/hj8/W17blZaVsoXLV2mgCPsnYfGS7RW4y6QQOHQbM7xd6BFwA
# DATA G5LWSjN62897ph6N5o2fRQdZdwTR+KagPAacu4h23B7M5J7ekvv7crfax9ghs7utTt5vfGuz8/HW40dQ/1ke6TNwDw1dL+m4Al/r
# DATA sSLX3OAgD1N2aumIJVBkRDY0inIywmpLKI3vZ5ORYqDpMI8gLBQPLGNpSFLRjNZfHaezHB3Fu11Ku3CifkfUQMQHvOlccGEzP2j7
# DATA jZoDp2Zz1XcX4XnGPWUpjCYfF+FAIlwYU6jCT5mabdA5c+5Peotck3vEc7Hyl2xbzy1NeoSpsfXH9yxyTHQ4m85wqYZghsoj9DO1
# DATA eiV5vQ5tVWu0gm5X7KFnOTjmUNIWJdBEP1KLe0/Jy1N1racunqRnkWp1SLwgHSDoQZSPQeDXtCM9Qu/LJYcVn1u21WLnYL3FdYpr
# DATA Q9vX4AJr5Qw6D/QqprwTlgbxY22AuKmIXWP1ZuPW6u7NW60731b/9/0ChkTMPX0Mq/kBhEmq9piEO+92NOFomYkFJwFkYRtAH4fp
# DATA YAf4OmIBgbiKWfPAj6mG/D5JCihXsbBcgcuxGYkihQxMGYc4F2mfe510GhfEtD39dg2dGgtzJ74Vubz6iBliW+BnscwWMhPEtA0e
# DATA 4TUulUQNtaYvBxABibM2+gEZxfPjtDc6hQjJXAzDVnMZ8j0GzU53NGiJs8AiF2pdGZGHtM8ynTh/p6QuTC5S1zG2EHdYs70mwz7+
# DATA fKYWDvRONTEUremzA3yqn2BJOVSveJ7boi6qgu6bZn08n378hndf0ApvLr2nayE3Nxpl4ucZCEQWVmu0Td+sGtJVOYrcXHbW3BZ0
# DATA T93TQNcQGQLCffwWyjbqtk8l4Netm4v0+anuq9HHOqKqFFM5gEX9iaLqJONUbC7p5KNEQ4RTVDAVFJYq3LPNUVTcwlKzK/OHCKnf
# DATA QX4p12pbWVb4/XTUe008kibCVQp1qobBU3/uNVb3/X1SeW1YvVu/exvuDaq5ZJGFkXHGpMbV+r40yo/BTAQ7gnTGg+wo7Z4FnEN5
# DATA AovLE2MVuO8wOHJ2ULy+1Q1nMy5lmK2Hb2Jgmxn2sh6P5pvRQ7M0kRKK1GaZoopSO2pF2Us1htPjjOo/Qc0NcuAUQKDACwgkGL6Q
# DATA 4/2RKFE/G/RQynSubPbgFMmKSzmQmurRWn5ZDzGwMs61b4giQ1BTrxySxG/0vJAVQW8zcDMEqUa/RTxs/76Nk4+XVgPuHGTfwJ+w
# DATA Nvva1CuLFMx2tm41Of2jIbKj81zNLO0EV7WRO7kIc3LbQMguc3iCTBzROS/khgKOZ3sY/GgfiZbulo270eSnA43W0nHfuXprMqme
# DATA a61uDbVPEFgHAQZoZl4+OGvovYPhCA5NAJHMxEmlhxkYxqyZQAKdWNOn9EE3VtJiXnehS1LLovZgh3gMjUMk1zyAo6VDTHLUM6O8
# DATA CPYdtOxACl6yZcBcWh49OjzMM6EmX6lHq+QF4VaqAbbmztV3qMa21hzSTwQU+iMU7swbqt5lbCjjhkFv8BWhZu7F+MvN0ua8wM2N
# DATA XxRjAKCgVeEgKg2keViMquL0s/OBhiFVlzk0ROMK3SNtoH6YRojeF6l7d3/Ui70QOvCqZfjRPe7NfjEks6hySggzzTcTlff70YyM
# DATA JRmLYtQ0RvHliGMGfTB547z4w2wI7pO1UD+SezQX+u4CPxI/kyKWwBBiXBK3zwdKKH7hs0JnQqCbopoHoVrK1Cna608Pm9bIcn5R
# DATA 77VC98KVrmMVfAcFpXcGxinWaaAXuwOxzf5NDWpZh++f8+Ba+rTyxm1RHy4cioFFNC7abOj5smNcGrlBzqbj2bQsn12ZPZm8YUyX
# DATA URsAa3AAtmRVz8EIvGmgtrgkUbHTuKJro8FLbfgzZRlPQuYnr0fo46yBq+qRDzbRPxTfy0Ghb+3wrCbeKl4A9SeLqFTVuNQNPgI7
# DATA wRlcZJwJ0EFjebN7rDpUE0RWdI23Uxt8JWj89KRjvB2k5CuKORwJ7O/C3YaAZh8+29ntrD3d6OxufXd9E4jrtk7ciD5QZB6OTEI2
# DATA rSJuO1U9Wdv+/gdrm51nO+vbm2tPUP2idaZpTwlPqgbj0iOS0RkxPlzd07WdnU+2th/J6vQn0CcxOcapgH8algESmuEZ2JdlLGqO
# DATA Basn9J/yTtcyrV2wVR75K8gEELrdoYqIL+DVP8e4WasACzKuPosSDfoEoCwse96L+56kIS8jsA2t/NNua59m+qKDFVrBh+pP5quB
# DATA 6XMqb29UeF6gnp7M8mmZvhqrKyboe7fYxNg/ZL2dvP8jAaxWJ0tlzsLCnhVZNZvCNiqCF8fpGRhq61K161pfApPDD62+U3sL6zuZ
# DATA ulvAtcy3+lJ0hLu6JOOJB3XdJyH77xcAlE1lUv7SsGv60qILmSqThXmvoAQ4lQT7RZb+Xv/wMEOYL7oR3MNGR2rOgJcoidfjxuhW
# DATA bpJXc1fwWPDcx3ry1UP9pwwnaQWHK3CqtR3XHYYbeqddnOsROHCUejtjdbipbJe9A+4LFJQ5G1MoRfN8o90eat2jtqEwiaZpjS9K
# DATA GbRETrZsmU5ETL2HScM/1BPcqJirseXv3Aut1AO70iELCq3o3AoZFyAdpr0z9VDdYDGmcrZ3XS/IdUpwNNOoClBc63YpPUVXiSf0
# DATA 6ZzPQFGn2PY05+ap+8lFLLuIyhv0CmSyQekwVBUtY/i3uWsMT6a65tGwp5NM9eDoeGrs5pIjqvs6Cc/NaBstH5FdBjdwpTc56yih
# DATA x49BiB+p1VPPTSAcGeaJDBaPjhvaboJKzhRhhTGTU2f8ULoWozF/eqwOCXTtO7jTI/UBsDm0L5yBwtrv1kPYoIPy8UIMlegMSx+g
# DATA mGftMKiw91EpyguuH9A04i+bDgaRIXjd5UUNiQHYQCmvEJOJ/XvajB0gi+V03SIdVtNa61IbQDEMXupK3a08CapEeKDDailyoRqm
# DATA Ze7eDLf2zWjN+iaBfUXJv4ORYresY4oMFgl5oKMjMeB0DLt9gIFGnOzoQAmovcEZ3QGbwYackOS3n+LwNOtrr+Ze/LqKeZUf5Yc8
# DATA XtJmQ7hvH/b3JIPzNzbnfDqy8xGMZ4etbqwgNv1ycUyolr5E13XV9sxUVh5ymZvPuvVtX7GhbmaHjWRH82sHXim090qYpB4An/H9
# DATA ILtkWTjAHgX3DjA4VoYyi6OmSrnhzsdrN+/c3Xn2ZAf9Wii1FYdBNPPjVL2sjT1k0+PsVa9/BMcT1TwRMo8x5UVUv58PYzIHoQSM
# DATA +nhxczsajA5q8Q0m/Uni8lCiyD3mYjxN13kLXd8HVic5oyxknlMx7dbmlKGHUMByHX8t5jK6dII6azJ/3YvEdKNeKcemZ+oxWN9Z
# DATA 9GI+pSQ/OqajHh6qOBh9faXA62IYL8pD4FAb+9HP9wLFBdkJflPSinuVWqgl0hws2gBeXRpwddHx3Og5pyYtVdPeXlU39FAjKKUV
# DATA I6Kl75fWHdrKxOuy7ijxpEF4ZKFQ5lBPztBMUBr4XPxA34QafBOq+loHMgdjmGGnraKW3L0DwqM7KytCftDxyHayW9Hqf//J/3IH
# DATA /ADpvmlsioE7nUlVwoGkcwM658VZXvIuIoIx0X34j3e2Nh8h/HLpVYUIztVuHOapITKYtoGkSpQvQW9DXnpNYeYSBACbV9IwIHuq
# DATA KtocDqWaTcpjR1cXDLH8F/0/PzXG1x//+f6tlZWbbvzn6urqrVt/iP/8/cZ/bp0Oo9FQCdNTBDHqZdHRLJ30IrRX3IteZNkYo5zg
# DATA gCkegigC6JdyZn2gXqoDCcWDkaB4w+O0UiKEk58QEoGJy1RHcTjSP/pjTjr39pGhx4Pslf0xm/YH5tc0NbGeNseLiSPNTsZAKpaW
# DATA dsHFMNJp/kBPTHBvOFvx0vbW1q7W1BNYqCnXQOQ4A8eRLD1a/3Dt2ePdztYnm+vbHf4yXh6Np/ajeOnZ5oZXY45Eqcf/ljXQ1MhP
# DATA ydLDrc3d7a3HnafbWwCe59Y2Ozxdlhnemj2/RliiyQh6vLOxu37VWnIS2J+sfdqBzzsffLa7vgPejDbCxbyE50r2xbF3dtc/xYmJ
# DATA 471nw/50f+mREMOsth73LKuhcDGW1uAu2R5m09PR5AUw9ia78vQAyn6iJ2jpA/Soap8oIaSPlmcut7THifH2l4DZtdVND3K6La2/
# DATA yro74C/YNoeJD1JUteLL2CtFdDUE6hL5QmI3gcW0lbCytLdBAK77S5+kwKQ+OAt0TM2FXov1Dzc+hdnZszOxCTOBQYr7zyHL6gCy
# DATA SuhHigsewFI8H0pplrANejSJpgRs/bwdC2PYDRAx3ERJGH3loGmSE4GbyIm+Qx7NoVpw6rmKbjoGX88Oyab0sCJPJrWO/5V5mrQ0
# DATA zwvuRIEYl0xDS5r9cccpiamg+t2ptM/Y0Au4gfZfDTJEdFmJEFobX/TzDq5PN82n7uMZ5prEm4Z/q5FYdmsRF+tyaOzGU6hHzd8w
# DATA m0qXnNgxU1Lqd2grMcnl1JKC0U9VogaTHyPIi5r1g0m/py6M9QhjRfFpe8WEohNMpJ4K/M2yMXyNFiW8RIIng6k0iX4cnd+8eeGY
# DATA dvnNg+jubW0zhCtDbZxo5Xef0mca0XgM/7l7586tO/bOSrVUzZjWOQM7wtKuhZmHCx1Zvfkt3ZNqn69mC7y+6qt3wOnrgFLzHkBv
# DATA dGWL9OcRkhX+RHtmpif9AXom98d3MagybsXkhWCxM/vj2LVzHsbn9OFFlMN+jc6x+AW4kUOoK4vx5Frejmpxv3+ICoBz1AbA9Yp0
# DATA CTJSVIxKLKkeIGWhikwTKJPzS50f3Pg5warazRRaXgzMsEXMOi8yj0SnhOsAEyScmGl3HPWwynNbvek14gfYVmW/+dwcKtpJPhh9
# DATA OF/nyM8vovPzJfDVUfWcEHSreoLjxGIdZhX3osNBqu58THTuRRcXSxGmBefrB1RDnylpATSZx6ORvpqoW8doAm52jdUVdVUFQ/8Z
# DATA 9/ue+kov4fXB6Do/Vk+7U4MnTZPTm4zG6vk57RXQTYsZOY/O7dqfpGO4YtX5RCUXqre2YvvVv7VjNm/PecovZBcydF7p58dZr67T
# DATA +Xa1MZ/CK0AcNJWcZNM0GtxGb1BFeF/ebfS7J+qMq/+8vEuzpHo87DWGWf/o+GA0aeQwKeCRLh+mPbBp4rOJmvRMP4HhqEOlpnhM
# DATA 7iE379y5bOOO3mU4yVK1mJhncJxCtpvGdDRqHPSPiM00tP8J5pJWawV9UQ2oD06cuaU1snvjkALzS3aHfjtnfyywE668UudMSy5k
# DATA 59X/gZxhoB27oHc1ajJmDsAElth7W4duFiBKYkWpO0oI3Vx/uLuxtUkxfOyf65BuWwk6MN0mCBrzEPx4FWft9Y/gQ6FOgM6g1xSo
# DATA FdzyIWwpoIOILAyOeEo4iVGOy0GQUxyOUnLuQg+nPbXhqKNQPpyg2uEpeKKe996LMdFxMHGm01kopGdiz/S2gMRannXS8RhkW4cm
# DATA 2zbWCz0zcKgk+1KuUWT5GHTIaP60LTE8cdJXq91mXgYvf+hNiF25vnStlXYyCU5c2jan5AaoBlWRbsObOMoKlrONjTbVFmd1kqEb
# DATA 1s8NZ0Br9vlzA3Pf5BsAd6NJxZvs7edlcPL+p4exgsyGTH6baNNDXRvPGLOegwliH1KpjV68v9davalXWUtyxIyJShtpzQh1lPca
# DATA WZaaxYGRRYRTBk7u8HBK8aME4YEf0Pxm8AD5nJbcXRFX19SkDmHwPCZyKas2j92KxIc+f98msCRt20qHJCfgkkeqbqpOn9F0mKea
# DATA htQO416G3oRFdv2cYOpDHUfxnPk+iDQ4ZUZDqofT6OJ/D/G/MV9iRPtJ8YuKspzRD9joaX/YG53WAEaC/zYe92vIRHpm1KqXFNHT
# DATA HYwgCA497tWoHiredjBCSQp0MYDJEvGJj7qTVBH1vGluJ1db+eCCVVW30IpfbdXFSVCTtDmKRqfg6U7apz44cuF9GGyg6sZInlr6
# DATA Sp0rftcHeFDAoKyclBynwpuS2Eg+8WLzg95CdmlDEQEiTPTZ+GiS4lmKKIUTjwkdCMBRTAMg0SFHJ6FpTjs20mnjmhK8uWw31lwU
# DATA SsgmE5GjuRBxLy3aPhcoL1SvWgsQvKCHbt0k4VbIlLKupHi66KRjpDsdijmLFaOc+y0EH7iIw2QtuFCyUTVLV2uR5wj+XL1zQn3Q
# DATA VEBCa7NegT1tAV7U+BFjtFKV67C8GG1nhzPCTom4vL5d9uqomhxNUnQQ1mrK5skLUA2OwfLbxqbIFRghFw77r9pxE/diIwQx7iGf
# DATA HvYs4inU7SGeQms0ZtK3mLfGp9d0kGbCKWFQKmwZCy+OmGmDM+cEjnIK9OJknuY7X17IdcJeW0InpQVEXM5uaa+KCLyHxqArKDXt
# DATA sn7dN2PVQ9DQoCa7eXrcVzJorJ65CBnqQWnObRp0wd9bP6dtU3jNgYFeEXQJD3wNdKwGgl1npsZwDa8HShLL1K855TEi/4+ildHK
# DATA zZtV8/NsCKFA0bMPP4nEeul6ZeghNaRTwQozqLouMhCXLkTd8Mk/PG3udDZ2ttc/qumvdF9xNPJhyYD974pjfItx0hH/qnXCKGVT
# DATA KLKdMvRUAcUuJd71p5s8Hp3phRkwVvHVm15u3rI6ajoI2vW/cu9i6pu8m4L+EScEhcF4b6XxbdD03blYVtzqObgSUF1JJQWGGeee
# DATA YP6O2fCEZ4cclfIQIXV0UR4sAnEJqlFTZXYCleTjvSjmfiZ+rq+aOtaE3g8MaDbW2epCa17+NSRhWeAr9BGzkx4GsrPVirTzlrMv
# DATA 2haH6uOqMxFfJD+F08Fi5ypP/1cwgtJRhL3ivA3Be/IdrbnM0cHGPJPfmawFbCm4Eg805kHwKToZvcwcJKercihGCm9ZYnA5UwUr
# DATA PQveOMJQoX7d/FoMFUhBeZp8i8X//ziwGajDlQyvMOup7kQdvaZVFP9fGpP23yH7egDc6xLsOzxJ85iq8NpSLA7B3hzt43Of4z+k
# DATA Zp67TJ8bd9n9U1wKNkHVgE+mjcO1xofN1vL+e4lm/DXLQGvfadXtr+Q7ic9R/VXBXs6do+LkVHJcfydp6oCNgUbVxdED+kQihP3o
# DATA WptpC9y5iYKA7QQ9Hamam/saTaIOXrP4hXf6Fx/NQTYYQbjWdKQ6MpoeY7gX6jhkiJmiuSDChdcztpC66ipuAs8C5NdhHDdqewHG
# DATA ti9mBsWvPcgQa5kduNfEFlUmno6QFw7PYsOK1H8TgfKL3g3y4M5lvjgM5kU8Cjel9hzu7nFahgPQwa5fGeM143bGYXZWWCak8RWk
# DATA k3nSVbH6kqmaK3242CHoiSJv2OZcoKtX4ZS0li7dI2+OD+O9czVzF5clSmwEN3cQtHSXGDuDkvOCC2k340J50fR298StwCyzBDbI
# DATA 0uFs3BljcmZCMNYO+s7ZhXfay8pJPUdB+6RASg/y0WCmppeAcJpN9i4gnc80r2Dah5ohcY/wqxZM8/T4QiBLddVGwGTYCCV1YwKx
# DATA N3lG6fBYYgDDBfzcrwhYRezStq2tOfCYN88zpLzdHE0/BA/DQAhRASaKAfCQ3z/e/G4N2jG8fg6BLkwBC1lqFkw/LyQcFMpYJiDf
# DATA zgyeDtCbTexiyh6aXrGwsRKyMjldN+KGjo2tFVvDaDrZJQqvcyoxc/O93U+TJNysX4UjQz3a2HbnNFwJ4X54FdUK0phTE0yXfoBU
# DATA Cka2Kp+ycOV6DSbJpdcVOa9cnNAK83GFqfXOKoJ501klWBWvQ86BLRzwAB8IZ7HCBjhH1dbm48/8LFX29+YHkFPKoU8V58YH0q5K
# DATA bjU5COl6+fDCN3hqkbPAf4ajWlItf5euuDgKUXDnL7o7AliZi+0Ij9gJNH4jedfIt8TBbWdvBSiaLNz8Q7kTDRy71wNeKLxa9DCG
# DATA Qt2Wp4eNb1mAZd5c3eP+oDfhTcP7r5KzWJYsOUhRHOMusOeAbsb6Eui9k+PxmVD7GOOh+LeDFAe8Ax4i0FbhrXT74EYSAD41PsBl
# DATA YYPOrO6qiVQXgzNnWfPAuprBaI6KPWu6yUwLk4hfyFmkr/iqfTgCGVlfzHNm3oE2J5mBEcDfzmLrEr54oAQZH8kctRQMGlhiWSBs
# DATA q8sYFQz3t2YFJ2+Q2y00StZCGw4c2MMbjs+UQ0zR3X2Z8N0yHS65evfWt25bOBr4rCDu+7QMOjdO+5Mc08XnITh34RzCoHB1jQE2
# DATA RN+M4rZkeDiqYoGdKDCfyMpLjliIh+BrXwnUDyDlHMDFAqSfwVDO3ETf5D89OoAcQx0cegccydr4p3PEJTzcFLPoIkTcIrtCjMJ3
# DATA PFaPeFOgqZ5E/xr8PelARkK7X9Febp5XNUuC/kANQ+1E9njOo0YDv6aEsgwVdErpZ0BT7mw/PNSiE00rGRd2pcVNSpxJ9jb5khAv
# DATA HWMDbVr0JsIWt7F/qESCn4XN6rqgahUF1qJz2+4nBkVvmnaPO4x7LEaE6llY86vM7zZVx7VXznBx73C76CGfhI0t8R55Uu/vWRTN
# DATA lfrdmxex3+3qbcfD1t94i/4OFpyUK13EZaBql8nQH6s/uFXaEygSQTQwFMbIbtW1Zn4cF6U5o7NzSBzV4FA1FtWeDfsmPrIAaqGX
# DATA ijugA1J7LakDo+QspZgbZboSUQodGlWXqah0coRYL8WqchkZrDtBOqnFO6g7VAM+j9XjMbkVsQtmvte6ifiBe7EXm3aQ5sfPh+y7
# DATA EzWy2fMhotM5tBQ2IlUDKjrE8Ab5BCCys24Um81qysC4qARoBpJASl4aS3BiAZQCbjVtU9/enZbGlnU2BCJjoUUCIs5Yecif26rV
# DATA K6JlVAj+qwuBIiPvv+IAmfFs2J3OCKaie5xO8nZ8749+fP9BLYm92sDEMs3yMfgMYquqeqjDKwWtZJjsACOrnJsquEzVsBjD9OFQ
# DATA 2E7in3ruxj44vGLJee6TLsqk+sBZtm8ynu+/QS0GYZrB73/v/F60fujwaAIyVwp5CWFA9yGtEio19DNTMcVHMHgvP8v9m2bpNvG2
# DATA Ch90S+IuudPYB5D4nKFT6towyJf5JZ4U/tuSbuo2nqq2OlX8vs7kywFYsM0Zl4G92A9pQz+zjRhpf02TwtnhaUdHsyGKlMn5brpL
# DATA T8E1y++B31O0yJGJHikB/X25+QL5h5LBYQR/A34zaIfuM/zbgOsukHDqnTpi09Ki6JWJZTU4rk5cEJpWGtSwl8EsihHRlem4jw5z
# DATA 8PY+vuXN1XLhWHE+sNg+7EAaFKl04NP3wBYpP8d38jMoguuOn+45NfpQp1S+Hd2sUI6bMevbi1NjEq5wVS9wBTOEdSbGU+0w7LEa
# DATA DwOWhBkHDVQ3E+YmhpMQewCHCyS9qEI2g00YR8XBoGTmvIXOqRO3W9QP9RwjkU1G+dMJzNoEV0nzRVyYwmUeT4wW0aXEl4775AnS
# DATA +uqE3+kEYl16HVt5SLg1p9YpHbRWFEoV5WIf5Vot2EczCoIxwoRpHNCdkeGIpB6m4mIQdRhHGxKiEPD6UbAhAChnQd8Ix34otkZK
# DATA 40UxNwI8hv68BG+tV+5KOgTUOIyOQnwLvKzrDsVsO3mKrgU6xVPmBcjopd1zixeQ8aXgT24hCNisgYFNlKfxnXA0FuOEXPA9Nwn9
# DATA tXDNgNWzFc6zpIpkTTDPkTMGRzUnl8cBmKxRU5TqThfSGSlML1FlHSgImsqC3nnOFtYrZUFFyXAfHETZGEK53rBZkg2ZJNFW4qUA
# DATA 2Ekl3MgjBO3esx0aEbpavBSssxaqNK48/sg9SgQzd7ubPjLwD59lcYiwm3TiL0l3fm/zVroF5BKbHJjIJ+jinXeVTKIVLUvFXoan
# DATA zqVMCNxxD2y1TDbAYWI48raXp14ka2yuuY7wOtQh8yejlwCbYzS/hNUlHnBQrsPnJUREHZxi9MV3TNiXbVfBKZgN9gD6Cow3SRzF
# DATA iwvUb/tqNDT9aVa6KUzbsMWoz+1Iwidw1k0uJm3HBXEIp0RLQ95ga/McBJOkUtbiyEDOS8W+3uw0InaUGY6WKeC7ZZ2BttcXSLpx
# DATA UYVVnCHtn+ItpAcaItZSi3f8XanHgsN1dOyd2JGYecLDNHadeHwNmYs2SdPQsf2vxSX+TyWeBvHci+RhfAlvhLm1Fb0VnNi/pNzf
# DATA FxxoDEsyA24XJiGE1ujt2cK61gquPuzLEfL0KXNISpKFcB+9Pf7Qc40Su1yzAprtZfyucpMb1TmNV2Mv5j7dG6TDUpqniWJd0LoF
# DATA COaSjoTx0ysKtXFBFOSGCk06hhVj5QPBlo0pk9G4j7olQMdpgt4Esd5q+FPDQDZ7MjUY2KWVkFOoleuSLpZhx0IIIj9rOF6BDfAK
# DATA bAL0cUy+H00X/VM6/UXcCeOjOs+lA3zftAdfuUcJQ7n4sC78Z60/trlqG4iLQKgW6gcafsbETfrjggtKSG1T5ntia0MZU/cDfGQg
# DATA NuMahLGDyXoMf6KWgUqIRLpNCuZL5k0LroIaLdvODnlZzvvjiybEtC0V05E7JB2L16PbK9++K4dsOPNhbBCPng8NytHTUc5IRxgh
# DATA rxqKGofVSEduvyShLeKh+BOmqNpdDxdFO2UBiZ9URCHWvtPCQMQfM6RCEvkwKjYoRK36RVRkABOJMHL79i0OX4xYYRpdn3Qb3VRV
# DATA oYbr1dZQxa87lBsMcoo2v0wn/RRXozY3hFJtE+4qz8tF5PanimcdxgYBApNXsX2X0tpWjkStVLH7mPu3Y/cSnCJ9X+Ltrl/6Vy2H
# DATA fMRqXWIOxQbalJyv1tEwpFPM+03aCQtsDgKFAAox7zg5PWy3veVwkoHJZt1D6E+Co0zvBz2E8HxJ7owdcSoqBlHmTYhuVkxxjyrB
# DATA I1TMnlDR0wCDBaeXk3QCfBQ8kYl+ILdHvmD2WAt2lq+GyI/VJHcpdvsgM1DU8SWE2EMlLkCTxBurDEXUH7UNdWDjsF8gX8DgfB8B
# DATA Kke8EJHihPsJzir3BN4nIicsfBYUXH0RBSDnIl84KTPEHWeDsWOodFwdrMZc957Ll11cavTetZAEERyfD78CCEcgBlC4sMuuV4Mg
# DATA qs6g+poGF6zgEjCJTm1J6ODwUpVM84K3LersAmscbFN4sTjSaKmQt7T0bz3kSymkDkZdExLOCJSH3eF0QIZb9bLDroa6fXgWF11y
# DATA TFGTJanodGjKsOfhw+31tV3taLj96JPteU6IoCa/q9XkrrO75zRo2/99ewy67puXdR2EKQNscz1z0s8M16l5iCso/SrpOcxXZ/1T
# DATA W/wMHITC0e4QQA82KGfawkqcDrndaxf73PUQ0U+Dpr8rxOeVQ3xwFIk+OCJqNm9hS30I5DFExrui1LVUFOpxZWTmDfhQyl3qqmHC
# DATA HmjKFMWnIJtayL7SpmyNAYDES3nZaB/PKveaK9ttlir020KbI7Vrxny0VHjlX18v4wJ1CZUrm802R9KhrKhmLYoZ96xL/ou+IrZF
# DATA LzoHbaVTr768w63fX+OkOGll58n30bmnQfb2CkMbFdXKZgiwU6lv+0nQjo0f122imsUNhP5m7fkGdJmKwvc2qNaNWLffEH+at3mq
# DATA N1DFHqmayMq98JaTWD6R5ZMZ6EUZ6/d3Zcl8u2FzuQ3LKFLqhRGYrkaeuSeoXiqL3hvWYkKj7k4HSJn7uUahaiiBDpWL83GqhXAm
# DATA QM/i+CoHVeq9wOm1CbrNF9lZXpMcMsQxSoMHA8NMVfPDhrpXQcInt3EbCKN6UJunq6t7HQrmabJ5XCYnqEZbCqRfYszAktw3MqtY
# DATA E1HW9Y2+hr+a65tb65u79cj82l1/8nT3M/Ng/dONnd2qhEblpJIOgGd5owVU5J4iYY3zBKFgmZQNOqGXS0EZeA3Qv3T0qGThdYN2
# DATA QDp6YgD25EvY6gp0ATVfIGcXYvBR+neASSotAFS8EIqPwqz3Ssq0c4BJSDKlufTTqmKtlArWZnv1EsEa/86X/dEs7wTczYOXHBmV
# DATA jkrVcCkzOajQOzdQoXZRMNBdNl5mKBImJ/5Su19g3c4r6yyD61zShvVuQUDSSLuV0DdO7aBoKshqnh+Ni7YNycUMZuqS1mAiDKeD
# DATA 012O0e2uzFvCPAKBQ+tE4ZZcj4KhGECh9gsWBKzGjesuBzJbYMcK7IMRhuacUwwq1uqjCcl4JQsUVOyf9tejfD3WPFhAFPEjs509
# DATA 5OsL/NrCQCpOFX4EdGDucVN1OjAPnY57qko+dlZJ4Hufs5m0Zcx3eX5M56eld5mwsbciCX7mnreWOwz12h6VljgjF4VOkorOKOOu
# DATA wjuLJbOh3uRXFSEIN1U65gYCuQss11tzwW4Ld3X3Gmu04gj82MQIoxDcEG+5yoSNC0sn1ZZXEYYvu+hLsHLSNOVhRF6SRvlRGeCq
# DATA r65Ww99DSlI+wErhcd6CByjdojuu5FOJleTkhcMUcFdKDofvvURjBB3rZEdDMYYGjfuOx684CEIVaP1FzMex16DzjnoQ8D9tsFcq
# DATA fQc8Jq4Lt2fzA5VKGFfRn4pGDI7TfkW3G9xoZREkLI0xefIUk8atVH6s7mL+p5DYLVy4P0QlduGDqgYKCpmygToRSDrVG5UN5XvD
# DATA zGwavbhtlqB4DUfuT1m3iVDv3byJKcA5F7eQAMrCexyoIpAhW+V5y+Jtlma8PCKBLsttJWHFSTKWwX74pZCFXImggBLCLvxWpC4O
# DATA ye+Lt6dl5LwTH+f1xOQzp5CzBRqDq497uvjQud75xeXFQuQj6vbB8Qum7yp1ZPO0J/M1KO9EixLQYeid33Rk6RIRuuiJnbylO5g7
# DATA d4y5tLey76ULdLyUEWISW0KetGIqtArg8JbR7RRP4YI71iOjFrej8mYURmb1bT6AHn7YfwWhB6rHDVpUAbXxcgQQ/6CWW0Zb5USx
# DATA 8TxKu5NRbhG0JxY3vHCf/RrumLrZS9+Ar9w3mA9h6XKMZYtauxzrloebARWVgSNLOxDDHoUtQIGdRJJA2JlyjwLXQdg0Iey10AZm
# DATA 3qhxiA91cWs0gGhKexkyhw61KZI/eefB3FlLmQCa2OccjzAJvJTawSeQJtG8oFaVwdrmVu+PRFztMcjBoUOsL6skY61FKKv2erxy
# DATA Oj5ZWbUdT8wSFJQ4vOVoqN4N13XGrYeDSSowyYLlrcPk5W67+DyZs+VQwPU2mkD/LqXz2v1iQcL97jZxqebXHkx/FSoHMR+9rGxu
# DATA yv3yF9D8lpx/utW864M/T+1WohEgMbywpz0AWQwNwCJGmbKfJEJdVz5PFXsTRc6yi5m3sWRWkQKfMFUskPWZEz1/4w//+1f8P/TS
# DATA gnP+FeV+npv/eXVl9f3VO17+55Wb79/5Q/7nr+N/flJm/TufXi4/cxdULXkwW/NxmkMiZvNzejK4ZN7mevR0NsmeAv5FSRrnrKvE
# DATA qTyYuvnMPJ6p64Uiiw/Xdtceb33Uebq2+7EWtazC3ZpkY3M2Okr0SgejI/IhBFcxXYfOWXyTExbLvMVP1jY3Plzf2bWJjcFRFV+B
# DATA CfXxGj29S48wckynOr57u5gWGZIhiNrR7Lqx+ZH5Rr13X+gP794OdM6UerT+FKfhW0s7u6pHnc21J+jI2TTpTIjhLv3x1rPtzbXH
# DATA gQINkfuKC+OlJlAVuSVurz9c33i6awrYmg7S7ovZmCvZevyos7P77APApInvX+uNcJPhBnpwH/4bDdLhUft6Nrz+4D6md0QolGza
# DATA vo4QeeopBnk94BiG+8v08/5YP4HLj/Vwvb88fnB/GauHCIWNR+ubuxsfbqxvU/hLd3Qy7oOkgNBGGtcIYY1uv3/x/Ptqa3y8/mmg
# DATA 7CFiYt+9TWV2t767vlla6tZNKrX+6e765s7G1uYOglg0oVcYsdLNc8roSf/kL4/w3+mrKT9GwThuvuLyp9mBOqr9QyVsxRdq93cH
# DATA aZ5HO2qy6cJs785Gr53rEKlOEUbNh1CbC59WDZ3GyknTm/jRs6ePNx7CRvzjna3NznfXP3NsOGGgNBckjfsOM0GIjK2gbU/oiwg/
# DATA 7eBsWnADYaC6IPyiF761AB5bRwCy6YyOEvmJLzQw8keZeLqddWcY7kDrFPDkKMzjxub31h5vPMJZVHdbpKz4jZ4eJHEemqAX7G+z
# DATA YCdO7gOI0WfMQfVr9VuoromfP8ewJ3xR0bFnmztrH6531nZ21neRBMeJg20sCb3MIAXXrzDEMVzaCXPymkY71MgEBvQY4Anu+EBB
# DATA c7NA78uE0HjQv435oKHKIKwRvIBJOKeQk2YzvqBIt8lUAE01wyklvW7UvtNSrPbH48nwx+ns1Y+Hs8GPFb3YW1Xd+vFgPMU/ElXo
# DATA ebN5I/kO9wpu282N4pXskHvhQkEnJgwvnx0e9l+p7XsK1ySt0bBEKLnCigYwIzu9Ed46Lr3vnGXlvfcgunnn1gJH4NHWk7WNzVA+
# DATA HkPMsMbmBPK9j3F91GrRYe/3hqn6qc9+mnf7ffWbJ6oMwu0yJ1R3T55RiZHGOd1puFXJy3nPqi0hWdPd1Qv9BneJYnXS5lIeOgaT
# DATA DWUt6dYpD5pxkiSXnfggjQZVbQGX1vHBegeA53qTwx3Y1NRUO+3YSZZbtq8ppN9u6//RAdBhOo6UsDRVZBNegN13SuIvPOsfqKnM
# DATA UWMB6vZXt1dW5rBsnKCdz5483tj8rushGsYnr8YSn9OYXJS1zYdKvN7adhutjXJypASVB2LmkeWlvMmgo14l8noVovois/XJ9gb6
# DATA ZZUMwc5bW8yb8B/NMerw7WcTO7O5tdtRH64/VP347NIdQW+Jq0O7L9xDVd+zx2vbeN0pRWfvkN1JIGAzBZGUxiqiC0fZHGSOubwh
# DATA D/R+Ukj9ak9uWAncOUlfZBYB3wL2I5LYnTvlpwUJla2+QK2wdhyUqNOOLDQ1bldogGKToCmrQ2O1GN7023Pwm5Q6KOF8CeOfm9+z
# DATA 6ImkzqpdMjy2nB0V/oNMoXPYa1OLVE9xJXl8PiJ/+QYQDj6U4rbtQexr8jgCTzdr+SOiWHj9wcbmmjo48DJkE+wIJH9sLhGY+kri
# DATA yNKTAG6sCZGjEgsi62voVnHk7CM3/s0+n4eZ759G1Eo83niysVtEyefeluHkp4fTbDJ3dCE0fXSvtn3uD0d1bwjy9wmEOnSGBC1b
# DATA w1bNV+YXfWR+mm8qRAIc/8OP1zY/Wn9UBOgvieF0zlTL28QmD69jFtcs7JphYS03QNC10gpTYnhD4y9D432L9lJl/gmmPXrzFqXo
# DATA 0N0Ccsah8LW32vJwJjXmvm0Dri1YuTnwobjQ0ghI574uR4EthQSuyvhTrR64Iv8vg4a/jAhAS2w7d+lw0ALNCeScfif0viJriWg3
# DATA mR/JUkKfL2eznLs9ipZJeYTd+RZvnONATIrOWcE1JMi2eE1AN6Q1ybWQUmqcnkEZ4FYEuCUU1U4caEEDXZ32ZZHbKFE2rvPJxs7O
# DATA xuZHxTup012GvWrrfvsKMou/8XxCuN0uForJSqybBV0V/C6wOGxIgh7oBL6sHeACLpQ3Je/DFwh4wk+B/83hcvr+6szJI/WvxNZW
# DATA xSfpAFOMQht7AuLXIIAzmg4gaqCFFswq5Cpa4+/5XMbZy3QQJxXAm7aa5sGod1bHqh6O8DVBcWIqEK9Y000NorjtOxg68DceC4+i
# DATA A9332/byLI4nNfiQQD7ps3fQl0l6ilnuX02NxkaqZ8NK1p2z4TR9FdStKj6spvHyatZAHwP6HFTnpKcJ4w04R3jRsykFLxa6SNUN
# DATA FZco1EgfjZk+8FRkUxauroFtIe8eZyep9v/OSWWJuwkK7en3+36GGfetd7AWmiktQo1Oc1ay73Ef9ktGAkUF/KyjkoZ3qJF2LGxX
# DATA 7FLAzKHqxzuiasYFZSn20Zts9YTnut/DGC0wQ5GfvgkRQLQ9CETF+S9wrWIbe1DZvqsmtSYrqRrUZbGY+WX1eqH2tJLRaxNML17W
# DATA D37aJOWpwfXVz2Gzn6Sv+iezkzKgfonK7wHy84RzTcbYpCsE7VvNTOeqkm0AvdCd1Vt3V5L9JLkCsZHxu4zlh7NHy1QFk8wB3mYT
# DATA wOtbep9SuLHeqNbue5ke4gdOfPGgh4htsN3csGOSV0QEEuHVBGOQyCrkwvbpEaqHza6Sv6ApiL8b6kZ5fGL43JjdKPHzVysrqJbV
# DATA /eBdwj994p3MQWS5/ARpbL7zc9JKX1w43dGCPY5SWGrQ7JosKtNT1R1FeB6uf7z1+NH6dgfANdc/3fV6QjMHESY1b15dVWaMGPrU
# DATA C22Uoa0Ik3p75Xb4VZB6nMfpwWg2NZZk/LUsGrho9jEBSIaGfN6mC+nnttf/3TN1uXykJNWP1nes+Ojgr+S8O72wfPCEG4IXI+iA
# DATA UF42YZtm+7pP9H1k6BkLcdtqZR3pwG2dcJNuxguNBsRttW6PH2+A6atofjYUdJ8IQql5w5P1dR69c0XCWoaqaaJGPoAV/CG5kFzI
# DATA u02QoKfO875Vh6E/IzEjtLoVLPgwYS19BKy0Lo5IHZ0tNKYhVVOPfjgbTdmfNzGkoXBobBR2JrD1KugSu1pKEqupFGfc4L1ibIDz
# DATA yYbrFs9mLD1XxJ9nJ1UVVn9/BTlue30T6IIU40J7h5YPvY/MvKu5UEs01QpbegzyH1tVeZmlTOVtE4OdzjVpwuHKNAGjy3c3tz7Z
# DATA JMqqJSu382K/5Xu6+n2z9YzB72zYlYowoetqB3Rdi+koqtVXtM8uow8L6p2DmgtUJMGQQgqHYExwldJGhuOSyF5Q2lxCm/3Jthys
# DATA E9ay/unDx1+5mptVPxAOU6LsZuUvDRsvJP6rw8EsPxbyjJnvgt6Yp5DOb89xMOAdWhPBAuxhkA1zxUE6aNRvM2A/UKEOwMJwpq08
# DATA U7sgVcuUt2txHYhyK050QpikcOvkfqgPTvpdng7ZmZKVgxMzmqSYQxp3rXBDFI52OFUNgE4FX8Ym/Oe2Iv7HGecV4i1kaqv7MxJQ
# DATA 31Zo3hY/fnPUhLx2msWI/hXTrYbD1UNf89EWpzyfdDvO2VUHKZ92So6zpUZN+apwbplgUpslhj4OxjflzE7gF0HlvzPh787+ZoDu
# DATA Ku1uomM8e2G1pTppcPczWTw55pNGQeGShUzC8Lg8k7CxXUyyrrr3CYz06WiKOjUK0gRATU6vxQ2pm5zIn8XvW+4taAKB5WMkk1yg
# DATA OR6Na4m34XVZNyzJYSOOjWUOpyqsINVfemBKeRZ995VyLc68TI3qrM2iM5BpV/zyk23wyIpDD2Z0Xizvs5f/mTeGSf/sOTuD8gmX
# DATA +EFU9GVulfo2hQWy3e31ojnTP1OAhY7DjpZpJLhA4SGQjYlKUWr0YFbocNhUpuSm/stMswH9uzMd1RgPEsK61N6rJWUTWO3ogov5
# DATA Nv4/ZVabMPiIHRiuqEk6EdvQ3LoZdVL+vT7K+nuWknAXgIk5/GU59MkCNqcSg6AAjPVc7RtEv1qVznVX3ISWOr7XdrpSWrrXP8py
# DATA oNQcf9HMj9Obd+7Wyuv/KpwhgrAzb+EgEfrfJZwmStb2HTpSXHOXB/0W9IP+cIRH0PFjkF+on0lrrm/mIm4J5efQJq10e175GTFc
# DATA 8/H8Ph5wqL10CDlRd1RIQn+3bmtK5rui8vpgja2FMr2+zQTZo9OcjcGtqoYNz//IzmyD9LwLfEdKKjNBq1/x4i/mflPS0a/d++Zd
# DATA jr7AfhBnznKe4nB4D6irFf1VkwG8wat9qdh0CUcFlpA9km0ucVpFxuJRksj+GR0LosW4ShbjLy3BKR0v6hDwhyeuO+ZG6W9XjHZL
# DATA XOUQ5h1RveK+0V2fuxt6Z/pdu6Il80V/SJpU1kShMhVVUdbOBq/V3aZob7ua7dM+xsbxoQ9XhvgDoZTl3hD3bMcXsfD5nxTCS4yG
# DATA EAvyROzjrLmPAsYcKsAKWTv3hSEY+5bzQcDOVdoGroY33o/XPy0OFMstFIJAvum7Vl1pNc8sH/WHkdPhomEsZBQL2NixusrOY4lL
# DATA GSJlzxdwNASGo8iDkooHozOALQtpDe1bdZcxcZqOBIwZYiYYdhnYwI2XqzqBk6tIkvpLqqLgl7SO5MeLYSjGRXjuvBkkyMP6cMvS
# DATA 35e1CMJQ40JoxdNsggCK7P9RApIcZjsfPNv5rOjn4dzqpWwrEYWqhOqAji40Q1IbMZzGATBJino+yV92J9PCW3qMAblKZnEyU/Cr
# DATA x2pnfPAY0nmsLqKhK0BUOVeLRZJgqHkRvzc/KCxWNZL1ZRbp6pk2OqovCD1dG2SHEG/XPzqeuow2P8ubQIkVrTlxUvUoBjt7FSfh
# DATA JNAEUNU/YC0wBdQ3Hz56/JjzFMzyrIOB9QJK53A2ZPQPs6W4CsJ8VBsknd5U2wqDqnQnzVeVWamdBprp5Ah7hMnuqW/dDsI4ml/g
# DATA sNEZiwdzXs/U+323FcCEgRjvtlNJUT8Kc4/3Q/ijo3W9+i2tCbzGvzoBJapuseZUgIIxq/ThBWUwrDvVuKXwjS52k1Jdl+YYZrDr
# DATA nhifWjVaVGucwwIQRGoQ13c+2zFw60jTzK+tp5tbuzvPnj69qFhDOhh8eGpddFEFzZ/io+aJNaEgfD45NYKCJZ+qwwEz5Wiv9Xu7
# DATA EzVzMeU9tbB4E9IMh/0p1kG9sra7sbVJupYdkb924UMWOCNzD1fp6Zl7goKjWdvderLxsKMNwIrfdp5trn1vbeMxuIBLP56v5bgt
# DATA euQKx46WnRQz+Gfh6MkNA8XE706J4cgcRa9KeczYkZfPWbFSt7Tca/zJqg+LaoMnq45jcVXnHiMD8FTKoNGWhUJl6JgtFVns1fYT
# DATA mbd45qRRwDuNbE+6pl2Zm/46dbSJ2/vEkAxC7UCkPCFeuoZP43ZChEKE9wehCMnUYCvTvVyOYmotj+FvI5TCdc6hN7q9tqgE/R/p
# DATA OYj9fuU5GxZ0aevxwe8XDBb+YO3hd589RcDTquBnyj5TENbDKoARgC+CpU6RO/AWQ4cp8W3BEh1UDUzSU33NLrkjOLcDiwjjuXpU
# DATA 3fyLyPwi169Nl2Hg+q3DUjdTkpazgdJJ9xjsAq0y/QMXUH2VmDIVGol3oFOwHTQqhDpj033dugTGyymoFPhSbzuKNRR3XBkiRjUY
# DATA g3ut5UPsOErtyYt6UR2hJwSnbL+QK7YW1A5w6fnqAS6YJItrCOjExlKSsTvLngLnkkyhB/42lIVLDkewdBJIZGE2rEcLwNNfnm4k
# DATA d+lpkXyi2GKVPDwx86QuJl+uUrXYhOAPngrPxiOENBcUEjkBt5rMOeyCi9Sj6ehFpkTI0aBXj4bZKeMq1plFSYwIvQ4h0rZksw6U
# DATA dJ2ij0XTjpgnWIRFIu5lL2FOxTfuy4VupTTHqA/7bGd3/YmQAfX2cJpQm6UmcLLABQinSLg1eAHeXA1Gmq+suNE4ZSsp1DjhLW2C
# DATA TIIlXRpstNaGiLaiVU1HW5X0rF4QviQxawUomabELdwyxc9p77eitzlKMrsJyUSaP+l9Rs4yDg+NT09PKewMNqEiW+GdCgXUi8vF
# DATA HjND9OYX94X6m48Qy0ucqwXEBrnbIXfEoMfTpuSp7FT9DQfOmUIos/MOZtCrVS8Kn+2YDjc8wD8uZNyU2U3Im7XrrYexdyO6OW8G
# DATA zRfS2q799ZyVk4B35JAZhBAimeiwP+znx2X0zNGD8g1CeLlmB7D5fekLd47MqHhUKOI4B2KJEGUQGaMWoSiFpoPaR5eiIt+m3c+j
# DATA SZykB/RKdwTVJKqGQBgwJ++jcnU9Nb7+cbEOtCF526l4gzNU0bhR7XEVdZr1JBCtTDcil9HIiENe5Lrdf4UEg3kezDEzbytRNT9Q
# DATA J2SIvnKle1aqJLl40fynX1zZAsgV1EuO49uL3UTOXDrGVIsJVl3QJyOJW3Ly7mTyBcx22FlPSEXEx6IVi4omYdldDHZfI9PLXRCS
# DATA 3IuX6JA0vaBAH8aQ8yV8WIX9emR+0CIERP7gbMHiLSDQY7HSSwQt8sK3CC5uWg3GSnnQapZKSpzOWI9b13mZG8fu9trmztrDXRth
# DATA pIHPQwZxe6lBqbT09uReHbgiUn0uwjfcjbl0GWE08KlgO1ZEtJxlLtfLXo2VKItRjWIfFPJPO4vO2Ox08YRzoyt5y3XpLKIemXcR
# DATA 6c4mqMNqv5UMxXail5o7QZsO36vzb7v8iTZMQrYnKG/8STBpQng6C9dQ3X1zn7Tn3aa2GeBmsfOOb3Bm2roDc9X+NK+uqEvJIAXR
# DATA WaoSRKp0SXJ3OGLAJVQEXFfPzL2RbIyCtZQ4CT3wpH+EAVzu0XI/XXKN4sVxUS1J9aa/5G3fnrGjzJHj9PLCrFMyK56IoB3E3Ih4
# DATA pPI2FO7jFfppxUa3lXrkHwBflA4fE7hveKPkD7xdXT52uy0D12vsqm00IOOifBsQRkVPfSC4UnG0YKqn9k2d7sa9RCcFBaoXz0MF
# DATA LaoHjwyOGeddbrc5Ey+WqELDc5mhBAYgSSB2cDGuwraZh1vfW9/+DMLAP3y88XA3Tqrolhnu/ONVHFZxJYuLQ7bOEpJlTrvpE2Y6
# DATA 4o/nUsvKAX+dvJELXDMMx03pW87FFsI5DfCm+en4dBSYlSUqjyhrI2xpVn8mpcKPNNbh/Pot6R7wdU1aCP2l4EvfOd9BWGmk2Wdo
# DATA 71r9ThQfZcNsgltSfajPiaf3MZ6KLSOwGd/FOcLIhb4lq0vytJ8OKEJan1bHDYcflsehGZeMcNTXZWKTjc7hMuHJuoPvKNbLUdPo
# DATA GIvLh3eR+cMwCA7zB5erUODWYX+CQSZDSMTEJXx/CW3nx6LlaX+9RfG/tIiIEhQDro3Fpqu9rwsOMl7oFjW3aOhWKHzkLQGXi1C5
# DATA D8gm6ESWXCN3W50lI1lwoAVtnrPgID2J+S0ERrF+y5DFiqpCIWGL9cgxNJd1zBk7KvX0r4IyzvS2XgTHS952BKFw4UXiAKp8DAFI
# DATA LZu8DPnyuhB8WmfgM1XXtrhUMhmspEyKFYoQXWYG8GYGmeBj0znQsZGMCgYEjp8XgX3EOALWkHfHDnyGw88M55Isg7OeMqaGuEH5
# DATA +BrteKKI5ugE40Mw5lyDA4iLmjRBViJxQPQ4KBy5KkObDkajQcAVXnfCqsXMI/ICoK6ZG3cwIMAghSysjwIIn/UdAyxn18xx2HEM
# DATA bvZsWFVOwMWcL2O29KKqaxv+XdBeq1kJKa6dEHSabhvnwrXBb18yMIWqpApJmILnE0vJq3y73DOqYBsijETosRDlnJvIkrBX+62S
# DATA LFLm/q8DoF5mrP5ZxFhlOqW/8y8rYpKD1HsBkkEIGwWKYe5ewXAuSS5M79yAGZcmiELi+b4kE6IIP9u/8GM95Ia68gZabBNdSu0Y
# DATA 4AOha0ZgFGEVarnYvHjnSVsX2L8kZdEUwVtQDp87DZSFvu3tuy5t9cW+MpF+FcJD3f/cvHHC/0o7ULlVQvd8eMbIS85kXGWqK4Ce
# DATA CG171O+SG3G/pz7sH/azCZpyxE9GgNLdr83fJBZvEyRTeCKqa7eLfDyxisw8G2i9fm1Bfu/RG+L/nPSvSUOs8UgJksywzLZgmfiV
# DATA fuPc3HWPgnBYl4bEkoCRDi6WbkfgYtnY/hcZSBA+rk/B/h/gsJVeAL4M67sJsZLIS0dxWeDIaTpRVxyM94ZuLkcFeAzmXFSw6WOU
# DATA SPAiLGEa9v1aLSjW7dtufxmgwyLJnfPYbkiMH4YQVGSVUnYfZc3J0WB0UItvxElyUQcsvvYgPTnopVis5WcSq+ssIRQpENLE+ggp
# DATA w4zVXkVnnQpnKCd+tWU2qY1kbWnJNRz2zBGNLQ305xG5MuhNR9k2fx9clLXO7ljS88IhlI5Tj5mhEs+eRVRzQc8exwxhtDTXAh4g
# DATA i4aWS133Zd0YO459UjwqZBOU0hNTvV4spMQgb0ECF/M9JyhsBfzqyoSvss3nyFaBMVmpSs+UFKo0uiGm/i5exahg3SgOO7a10ttX
# DATA ECy9+HW5l0Gg+ML3po/WN9e314S5+Cu9Ol31dmGt+KJHVCrx4ia4qIgKkY1q0OcF/SN0ZRiEc6noiXjRiw14FpXeIxPnylhVLuz/
# DATA VAXYY/wEOk/XNx+5eLfWmlEiA19GcVM0XAQ2LI5vQZ8Irmmhcdr9HSCFbI4mMafc4h5yRKR58fxCnPGawtogCHxbPwNvWWpRD+yt
# DATA bN1Mj3odb12Cnvp8LabG53vh2Hgk2YS/SO5ruVp6zP7lwOux095cadJGYy3KwnjTWDtj3euD8c13Dn01X6Pv31Ip4CoEvGl0Lhbe
# DATA pJW4JWOdDpezQ5YqAwSDLrA21P8pEfalm8dSyYsTdISiPOvNtcnRDCb7Kb6pCaDndrxBDDw6mA17io1HivylgwiIrGYXORLG0Wwa
# DATA 4byBXgtyIkCf86ZJqAs1A8Z4J+XGanGjIXHXQC/ZfmrUBGVfkLRZWUbgrKhJSNXMGCVq5Xc0e40JOXUu1h+WgIC9dGnCSJiYqo1T
# DATA 3RrM0RU+422zcAc1eW6ITaT5MAKs8Xf4D3yZ44ZJgmmq4XUTOl44/3SAi1d+dKXAz7jjBaccfOlkcbTmfvUmxF78MloM1b9ZBV5p
# DATA d+NhU7SsnVc1lh/OVGfySOxOJIrBqaybvW+2AvTC26eFeXJETncC6s5s1Usngd8EVaVFK/78ebZztth8+ZPD36d2CnvRbKjuZjCT
# DATA sGWg6lmuqGrJnDgWkeCcaNMI/rCmCbkFqmZlPOmrIyGAl6npRZCXkwLrWJlnxgrgghQ6cB5jCWYq+Ddc+ov9UXIx3HPbgDOQT9V1
# DATA flLo0Koi+ea4moQzoGqzSVYEZL85qftLYSuqUwUA+cPFFdGHOh1UZHU6sBqdDnshQNeUfDutIc9RE/aNy/8PuAquv9YdNsdn33jH
# DATA /1tR/7t7+zb+q/7n/HtzdfXW7Vvv62f0fHX1/ffvfCNa+cbX8L8ZYEeo5r/xr/N/fu618+uknrreWq1fR1Hjemvv/Hq/d711HQW7
# DATA qaIP6qhcr1/HLBXq8eu/ffOTN3/x+os3f/b6l69/9ebP3vz0zU9e/zx6/UX0+nfqr9+++VP1TD15/SX89frz179VHwuBB6r4P9Xr
# DATA f3r996rwT0q+qkfq379QLfzmzV+rIq9/Da9Uo6qoqvJX0Jr6v1+pp79+8zPVjZ+qf/9GfUg1quK/ffNX6uUvXn/RVM2jCut66/y6
# DATA zqGiOnH/Wm+EMBCY9OLB8+fD+/BHNFASVvv58+vZUP3nwf3jLO09uH+STVPMUJRnU3iJ2jN8j2/g0MLjl/3sFGCR1J9agwaPT/u9
# DATA 6XG7p6TKbtbAH3VtCWjkStjL2qu2ruPpdNwA+v4SPn1ItTR2IG9Zf3rWeDoa9LtnXgMshDXySTd6HufZ4PB5fC+iKfcfTs8Gmfes
# DATA f3LkPEFXuda9aHTwA7X8/GqomBYUPkjzrKH6Ih4BKEuDxCz7tDg7YhN4/V+LXvbzGUq90+xgNHoRYboaJeUeHcOd5FgxkuPRoJcj
# DATA K5weK8k4VWwxyk9AcKbLBCRUjkDbrZ4rtnQSZWkO5onpCJhiM9qZznpn+O1o0usPAXaJkWSVQAci9QkAQmKvcas/eAqqbRBvDsF7
# DATA JPpx9O9m/WwavRwNlOh3f5kK3Ud/nUk2gGH0uzQy1d1D+L2c5mq/5MvwvJm/PIJ3KFNC2RNV/bJ6+N6rkwG2KmvCVcqPs2waqg+W
# DATA oNnN80t+hnY+/RktBUDoF4r8AEqAYJ9NHtxfpoLqDzwJcEwg3R9uEVQCweeSVGDt6rAMVJXYpxf9sezNN4F9QaEd9QJWh/fB/eWU
# DATA Thu0Kr4/gIuFMxxr2oNq3FVRdQzTl0pG6aeNQXpA0/IE5Cb1uH+U8uaDFkrq23qZTeAcY12iVK72Tz/LTbmdcQoHOOLnfnHYgqbs
# DATA NuzH09HkBa4NFl1W/eFJhQGTaNiDT/X83OfUTHYqxmDrgS+IMq0+2D1O1RKOQSY2AW1qi6u/law2bKrqVx/cH6tiWQTfquNxFh2n
# DATA L9Ufo5eg3YXMf8d4ACCVI76G1UAxE3bqqBmpb9W1Gd3hlCSuTtsUjtjZaAZLBx9rRZU+uqrV8YP7vf5L228iDbm/Mw5m06l3YNyl
# DATA +EAJmbqZg0zdewFvlyfaqwXMg6NhT51qp75FFm1Z9RX2Oc12YNr5AU36zQdbk2jcVx2bjdUkKdJyOFOTMhoNYLpvwnQ/TAfdGZoj
# DATA DwcjlP6zlPy7I6T2UW+SngLFAb8+mGG1XmZzRL1RRkvZy6aAVqhuEEp2ncHZUh0Huy8C1yCQUXekRPQ+KMFp1i+z/8x4l2HDPbh/
# DATA qER52Ilj90Sp3SWnArS+dEuAem3uKFWfKvhAr73TFZuIDL5ZQ8r+R+nJ+B7I6y/T7hl0KPp//ym6VP9p1XSvl4EowXliXq6Yvm32
# DATA D9z+D9x+HrenbXkFJv+OefzVWPx8Dv8/EIN/x/x9IfZ+Oe7+tTB32pFy+Iah/8s5QUjw5/NORelHeaY56Jpmm6TOUy0id9f8Uw4Z
# DATA 5JrUDnN0yAGQauxqW6FahZeIp6DbnyDzRQWeNxE4PSjSaBacozptkKUThPI/UUxb7axBHRmwGkT/JOtFB7P+YAojAPqY05BVT5/l
# DATA 8AlKW7p/egTQguXoXS0P5L5AQOLAaDg4a0YbUy3DdSHPN3B8mDjFtlDTbM3aWhRIe8BhUL2IXYRFaaBYAGc9zxHHKNrJshfRD9Ve
# DATA AWctbVw4zgZj1FVBJ6P08BBWCQSS9DCbnpkRfjaaTSyP5qEpSSePJrOhETUPwNkpmzSjdU40BFMK45iNQVoBOVPvQtjjOcowqgCk
# DATA UBiBkKTIQw5l0sHZtN9F6UaNLZtMwcZ/pIaQgv+Fdm2DurrHWfcFqjzRtINqT6cz//0n/1vOYwUtL/oF5d3RWNWD8qRYs2b0ENY/
# DATA Qrs8Il6ogZ3ByLku+OL/Y+9dmxw5zvzer1IOrZbdIoBBFe7dnJGHN4lekqI5lBgOUS8KQKFRGgAFVgHd05qdCF12V3Zo48jhE3E2
# DATA whG2wxHnvKe0ok1TEhVhf4Hur7Cf5Dz/58nMyipcGt3T3XNLiWQDhaqsvOeTT2b+f4jqMV4RTamkRjpQ9rhSWw9j6osmUYXtQFBM
# DATA YChL3s7ymFObWHBh0zN0h8kRjw8GqIo1v/d2cjITMw8ZKTvLBlRjsGOtFDWpp3JLBiOcokqtHD3cIJKKPk4yKVrsKUzZxH8YRfO8
# DATA UYeDAWz/SYLGMBjw9SMEFEMhEcJLnJk0eiCcrOZ9mPB9Sy41uj1KuciQl6ZFIdA5IjyOdCdB1ecD9DbxQpJAQdvNhXJsSZWbq7lq
# DATA rbpVRo/IWEQSTygwkxUjnrwUCvI9irHZuJRB3AO78YbSwXg4XkIllMb6XOkwRBRr3pvofGTvAYokxbgYUd+iqiu9B+e3+DepUsra
# DATA v/I0Z7fBZqcZzo5m8q0Z+1ex9a/B1C8aTWTvf+dxP3lE5svPgK/pcy2t0pUneOgxWTzJZFLtRzQXjpP0IJtS0OMnCPfxNEypNhzU
# DATA D7HCcZTC9XNwHKZ71eo8nEfp/uEgmdAjconssv1D9F8Hfmf+6I5fa7c8+QVh7R9ilzl1+SfVkzScH/SpBj6sUtqGT8LHEkw8owYS
# DATA Lw6h7V9dYuso2XpRNRmNKEEHtSCIpk/CgzHCecz3DMEC4UZSpco/eDijtnsQzB89kUpSiWfz5aIi+7cqeAJjzWOOonqXvrMmfx8P
# DATA 44yG4VP6mV89mkSPDmm0OJpVecvfwSACJvrwp9Q649FpVbUvfZnmp2S0YFw9aDbnjw7nYhwcUE5Qn+n5NR9/D6UEDvz5Iy+jKc3Q
# DATA s/JvJaPRecwWxZym9OrLqjTTcBgvM/WzfKlQDKQ8qicSp3arfkhTqYzCmSfMuz4sZeMBJjAqT2qmiencya88tqJJ3dQskx1TK9VB
# DATA BfVjtlCxlzuLhnex6PyTxysJ5eTbAUgVU0EcUMlgVBk+TubhgGaDB7VWS6dGzQGpcozIQMiqZA/GGIHUo8WLXClK16SKlC7qClO+
# DATA dzmlZnFavPqYmjZqzEGjVKh8F9V9+VnXZSqaJxIP6q/3fsxTJB7GqVX+ZN+6iKJMfrK/Uod5Jn3g1+vfLlS6NlW6DbULr9/fvR3n
# DATA VRc1t9axKq6ubA2diFL8K9ZFib+KbkBN81BFlT9LJa6udiLU7KrZOKUvB/UnheDIVv/JYx25+hOTIVYu+N06hU2VLf5ZdMCWEw1T
# DATA T3h+ZNr3URoPD4+oG6o1OGWFZlKvy901TpJ5ZlNnwMF0EEq5/duhNinUEagLVP6Pt5aRTp1fC1o6VMlAild0RKP4YzvgTr1uHql7
# DATA tSY98mTsV8ZBZdyozFUXXl0kc3p87EvvJ6/D/ApmsgRUAWkZ4910vhfUmnh1pV1rHZ9UWjV82acevd5UMVV5sn84IUuIqgTcroiA
# DATA /EpdApM1KtVavdGiRw+n4SOVBr89GB+qSPUTap9TSmiDIx3sFjlfutNKg6IWcMYjan73gqhRXIIWsrP4bn5zQ95ML/FUrlOIjXKA
# DATA xSe5ZTxBBuuktTuD8ZN4elTJjo9MrWES2qHVXlUFCZeL5InMiSu8z0BGdNVUgIvzgzpV5AomTHt40qt6bfTpJiIySNkhXVhXywMX
# DATA u8tp7F+cRNGMa7Jfa5Wqsl9vmW7FZNu6mvukxt4LycuO5GVT8jJYzUuda0GdKsTacYjmEsUEcb/A1gP+Iw0vUEMr/33C7pALc6Hc
# DATA Tje93Qtl5FJe/bswgX9SNj0OjKVyWGqWT2rwBj2GeALfOIofRcPDn1XZB0PpPkSjrPoo5UMQNyinkdEbumjTLSCdHLIMQY8RCp58
# DATA UiOTJtGdY1WYgW2UXbHXo/+YPWvoe5fTWXbgj1KP/t3Uv3ED5fC9GlkO9BpOK3ex2qzJi7TZooYgd4/io2UaGUMyvzoI2RtqhVPr
# DATA BmnePpGqWpdfq6YSF9eFbul5X9poTRn8paxp1fNqzXevr9PqYe6QilHYuTHZmUrd90r317JjyS/yqDMs3kVZh5J7vENZptGcZoV7
# DATA jQrVcyqUvXqFSpa6jTxGT2qDMB0+tkYWa9Rp81BfroXZMh3hCPcF9sV2c1Te680PMPuvDsbxZLiaTL6lBvd5pTZd0qT0sW0g8BUK
# DATA CL/blacneXiCbfm2NdBb26bWm88t6mSb9G+D/m3DtCqVE9fPQgGwz67YXDYY6maAQSCl3lDSfDBbjCVP9oLZvqfTsqkkglWr7UnN
# DATA +E3LdZ26AUoWOglzi6esAclAM/BjaMWojw8IEb5Ka5DrdNG2+apnD36dOq5TeuLFLnWUMlP1OLp7KbQShto8qcG3YKy94CbrJd7E
# DATA izmrJqIeW2pivl2iBQZrWyCHJZsBHxc6KzH37H7eU3VuSx1QKePxo7luRmm1hYZ0RydjPiyJ3uqAJmXci+oYHVBSFqcmjTwS1mTb
# DATA esHGrrW01ayaXyDdivZFrrG0m3bq6oe4q8oLOOotuR9zEj/ewdwozVGo56B5UzyIHttZUp6P6eaom4eMuzUpFJpeHllGlIl6fYdh
# DATA Qp71Qkw3aD64QyUp1A3PfAvwDTbdaoOwx5Rif+3VdzPQirH05tbArH7KaHCfHT0u+Q2ogYRHZe+ImLZb6qYpoEAmkWmxznTbq5PK
# DATA DU2zH5ZsW92SVsbWkl1Q7sLFIFBBejIpxCMHvjXP8pvcU0pTyDO67LwZhtk4Kmbwj8fxcBjNflJoQP9K8IDhbPGEmttj4wd7xKa7
# DATA PTfC/CB/X/OCpm9nZXdTwy653cLZ6Qnc0E+wNiKlPAqn8eT04C0ysRIalyufvfZ+3Nd73z9IZslnr1Wm9IfDLbZ5ysshjcPxJLOy
# DATA Kdi9PipfyuOSV6rstCrZ6/qdXmF2y01YTaIuaq6HxdGRYxyoiU8eYsMe7tcZnTsYgOUq381jabU+qw60ML6qGwpuDZ6p7OafpB47
# DATA 91aXZqIbqkNtHk8m1TQ5udjKVjb1IpqbUtfdaDP/CZ24af9N1UEv4MLj8Mqt4An/pAuOushJOM/IKlEf7Am0XQN5YF6MK4uhTMs4
# DATA Lw4Qm8I4ulNlXGyztZ7UKAbRY+7JpQM/8O9UfR4bLR+RZTSIzZAsF/Plgk8klDNL5lS8S7+KZZs11iyOp4WLJH2sh911tqzUaN3R
# DATA mQr95F9Po2Ec7lkmWpu6tf3HG50Otqeh0Ubfq7wKxdaibJLV0Ykri5yiwHRXssmuMzw/3Tj/LDXKBmaudlYW55PG6dLivprnRpcy
# DATA xrSxujk+9svXTyEbWGwozhB3zJYVg2HztDwYaR9jy7JS9IP37LmUXT2DkvmszdjVetFscL3gPKxoK3djfNgtI64XHtV7eeEUJhSB
# DATA uOnUVLM4POye+p2Ty53ImvkPd+RUlUy657ykmVXTaLgcRMPqNOFika/UOtatiXHg36l850A2fdCHcIR2E87iae4yysf5Q14Uidf8
# DATA oqMhp3N0W5RmWNGLUWWHh9jHXJrK/LBcvrJSZ/UKbAWouWGf5qcPzWyjfNOTJ4UVQ71rCzsE6Y/3aDqZ8don9uUd3LlzcnJSO2nU
# DATA kvToTlCv1++oDV7YQPRm8gg31r26127SP7zsixrvyQZA+s4XPenI8u8pP+cH+DyiIYj3TDXqjWGzh42P995guRLeLfSB3/b83rgR
# DATA HHe/HzSP/fqY/tv9vt/+WeHhUTBqjBryMKJYXBXNaISMnj6RXZrI02SeU5BM1P42vjHfjEUVt3+KX3jfXL67Tm1+MlftReeDfEeP
# DATA 2QMQDXkt/NRswLOypFf3ms2W1+g1vaBVnzTqged3G9VGveP5zUYxY4btYT+qr+Zqp+E1uo0f+Z32JAj8aq/lBT49Xu8e09/3EXSr
# DATA HhSDikYjn/OYpwsPOf3farZa9VaUX6yaom+svBShdv3jZuBP69XAb+KV1V6PI6Mi4vlSK674hiCoe0HTP/aDxsT3fa/V/VHQ6/7s
# DATA g2aj5zV8qj5Bd+LXO9Vm50dBu1tMXnfQi8JwJchOi3KlN/aD+rTartM/x/jYpMuNZnfs+3S51aJ/juljKeb9dr/eHK2LeXNjTVXb
# DATA F6miHuBk4WPlCT5QNfyQ5/cHqrEc6qntwbfarXa/gQvG+0SP8P8OjUGzeiU4+FbkR62oc6h8bAffavXanU7rUCyMg2/1R4PuAE+w
# DATA 25l+HrYbwfBQlvcPPnvtQXSURN4P36PpwifhmGzPyn3ePpZRV1jNojTGs7pL2+l2dE817LYkkynv0g/EmvSCotO5K4aAud2MRmp+
# DATA 872I2nQcViTo0tLcYdkRBuOs0qk1j08qHXGEccBqp9wu0/ut/i2aqRZDLDvKbTNPFczqA9qHXhwnCnfNC1almJx8A8afQYydRI8v
# DATA sTyQrwWIB7BkFonTqn4548aDi7a8EaPoFahvNGYLqa2sJO0i40559lbqGJsNN2mpPFlt6z9FU//sNezeo04iHix4J/mMN0B6fwV9
# DATA Me/uPbMFsvb5MkpPH/C+gCTdy/ate83N99M0PK2N0mS6t/65+5MJPWo9q/by/U10CulF/QxaeA3bASm2PLf0Xvc+e+3AjuA0muJ0
# DATA tmDHPgjnexyoYYWznPHD6LTijcLJBJV733uMA//0XwlAZPJ5T9kDiQSI1O9RVu9ZkXodGmX7h4YqzHQVeulyMvG+6+1JLGrjMMPL
# DATA 9umSukJByZUDKwIHHo5+ihYBi+0fek9wVHkwplipN1wmRDz+xE41H6qXZCtU7GP9eCaP6x8OVV4U0p9tSH9F4o1aMjuKR6caW2Wy
# DATA BVts1qRlhMPdq5EMT/cwed43RRFBoPav9j577Vvi+f3sNQoaYkPRBIjWGu5WpzPoRnw7LAU5Tk42hinG6KXDnC2ne/FwP0/Nh8tp
# DATA P0r3OMzPIPpHv9Z0bhYeHapNpHsi54bARc+C3vTZa/h6h5pzPDvUx1zkjMtreeyXKaL/w4/fr8mOyx/w8RD6DvU2701o6P0Y4fyk
# DATA 4j1GwE9QGPJoaDckefqdScR6GZ+9FnI2hDXs/oNmTTrBNx1ftCaKMS4NJvHgIbUpbD39JJ5GyXKxt7ePNo5IpdExGRV5pCgccN/J
# DATA flVZIVHB+oYuBcwm8HI7n5IZNjTvjWZIOMoGD7AQ3hRCH+8cU6TfV1orFEa27E9jKsiKFx1zsd2jx/hjDaox9Pdt2Zi1p4qaA6Lp
# DATA OE2FfgR6R7w43dun8Ge44YmK6l8hej+WAxfhcfQTimSNHnwnHIz31OZPftGEjOYsFDE67l0oQviK+Pz4J+qN/0p6wDjjv3t8A71R
# DATA P/fjn+hSovzH7njocu5L+HL9lJUs+f4ajSqT5TDKVDTyDpF+pfeZTXKL+1raHiVsbX1D1B5wo907hVqneaZY+fHO71LFfCDJoQ5G
# DATA PuO80ZNDHdW9/PE1ZcP1Be/TybmOrNKfd8gOSoDcRUY1TW33jhELsIPvemtvP/B+XKvx52Fl3R2moMgCzpBMjgd3r1ZiJNKFLELv
# DATA lj9jstXsQ1/Oh3ozeWEDv8r3N9W29/V73A/lGQmLt7Rnajs7zoSSQXEc1biFP5F/i9XbLHgV63jyKK/gfEumi41+MpliHt5chPIw
# DATA laEJBYWIQFZsgM9eW7eTz44W/y4R448SAS4GCT6vD/K77onl27oqyidv7DqqTJBcI9eyX7ZF+0DF5TNIeE7J9pDaZqKwqeZsyE8d
# DATA AVV79Fey72ZHNBmE6eOxGe+Z99LFUi3TrWVDvTo0ByrW1yxUm7zeqLqj8wfmqhmh+ZvqyeUGGvVpbsXGGN+iv5e7e2ma74mWqcl+
# DATA zmTWJ+aQvyu56P3t31KsUSGo/5ru0Z/k/eQkSt+izNszWUwNIWPxNf3KwtNkJSHhXK9xYoLuqx96VoNAphYrHV2wqwaLLkK8h67b
# DATA nWYxNnlN5LTse3/9196ejtrduzomiBQHZKqAybe7d1VSUH9xiyzr0Zv/FUdBmht/3Je0vP66FJQydrByqLOfv+TmDr7tyx15sJIf
# DATA 6B3r+YiklIqkDHGDCUR+21f3lIYPCYtrKccwynjgoJLXJbqmMXI7Qlu0KgWSY8pxawMuPEQvQhxVNaVM1oHsF2scblQWx97+3Xts
# DATA M3722rvmUBiayet7MPs+e02aHqX/O/Kd54Dc3BfJu9hWtxfsv44E/+/f1z6j/83e1rPkJFmwq9ULF55PM5bXJQA+bEYB0EPr30PG
# DATA 053irfm7fH7X//kn60EdoR2eG0ylccsMMD+Q6Q5mu4PZFx3MdgeyX+oD2V5hu7E6B/1cH9Q2njP+uXACcGId334wZ7U8jGzxELAR
# DATA fXo7v523FfM5uefrPPeLcqrxIuEW21HK8ReP8703qKctN0O9SIZomJWKrqx3WSt4ciGc8LfiQfXy4pU06UGCzJU3nc4GOhrKj33v
# DATA BytrX2ymkj1QOvhvPcNfOB2cAfN7XLQHVO7Qg6Hygj2ULk6xqdg8PxfdgGwc8olYXaM8teGCpoV8HHnZp3HNg1fXwxyEwvyc48G7
# DATA lOIkrXk/mEczPuc74rP79JA6zM+V1aOwxqh1VCc92YbAGCbcTW8GY4ECmindgB2Vd7ySj1vrCPB5Yo42WQtkZB/hXJqR4fkbHHNG
# DATA hcPpbiY6eB8tjbvXm+Eyqx/JO2L6aTmH2ZDVPNhS/GPGJlUygpOHWswQlppqNmQuJywBMFqmZEUsV9UQXs7DtiYEZ7056+0i661Y
# DATA w5y+jtPXuazZttFAvCndnQfYwmbJQeA18G1COM8o8Dw7jbdtwyV293m2XF3BkuP1D7Y/sCiituToa1zY6ITEjmWfgM5k5QXcm+6/
# DATA IT5R3QBnvB6FQpLQzHOmu8qvsFeMt3/UWryJSGtYU/J5QxQuTkPeb9RSm0miOe8+qknPfofjWIqqeCFMdcC3HSKqnzLxNBdMNBu1
# DATA 9jVGUzwj9LP20vCFN8TRqiKl7zGRMg+9kXCHn0cuwJvv+QdB/Y07ibIKy/e01D2tLff4dXUTfcjvuiPRypOibHWdm2oVjB7Mm8HC
# DATA ljwis4GfYEMindJ7eU+wSqdaDcXopatmfkl6nviYXzSncXohOXBHgsD8SeWWrNPaoeSX9A41c+WeZXCGmJBZHYAtTcVGozT7JaUK
# DATA wi/GoPyABkPqn8Vo1F5rq/1jjI1m3PLZUDQDbZyKHVnz7g+HHp+JVWZBpofP3Ib03scailL1xETAjLRLyKaLo5eNUjHEqcfBG7EL
# DATA g942X04m/OMSy7A0qMepNv5/mEWivCMiNqL7E/djymKRmNciUrrOY8E24yiQWQLDgk1p9ESY18QZpoWUpJl0flrliu31CYTvrV4O
# DATA Y2A/Yr1MzjTu4KVIuDRefqvZHgCd4ewM54sM55KB5CxnZzlvN4efA8XKT+ht3Dgy0cwLh6o15GZzSbMRg4vReWNFxIfRggp0diTS
# DATA dkXpRWGCJSOMW4mSgMyVEkUPsWwkl/yz2K4opaC2LL4xbrD+nBZy1o2dYtwQl5kRqYQFg31K0FsMJboshp2MRtj+BZk+7gsyb5yc
# DATA 0M8elZAMl5zXNU8ZF5C0pNgdY9xFP5OMuGPgPLfkK8VnxckpDnqLkL2Z91MMVxMz0pkU2Ul7n51y4YBsHAhpnlCPlacMI2+Vpwyy
# DATA IZpRp+Ek4+1isHSQxCOyxTLdqw2p8MbUm3EpcTLllA+FMGNRcbgRyXQ6krmTGDHaX5ZMyWpcKHXBEFbBQ08rhWxJ59vhKffE2xOK
# DATA MhRXJcpYp/GB8j+OooiSNYxHLO1HszsYahA4xB5G7EOgarWQLRhMN6Zf0BTxC5uA3ieM4fGYL4gA2bJipiwcg1QVdUKMRddfnkql
# DATA Pl2gPmOT6JZEfhxlaxIoZkWhCq8KqpqqTlYq+y1PoAqPSjZBE+RRJ43WGbEo0oq2I0F4C4cxzt7JQCd2qhKTpNr7MfRfhpSJZBey
# DATA 7Yfkw85bkjHBTzwUj6t2KTOkDLV7Ku8Ue1JPpbXU6ShOp7w4sm5uy4n6hPJG5uNg9M5xjJTMJKO2Ti3IWM/54ncm/mu5n/KDqyOZ
# DATA Amp6HmZiC3Pv5H2gxT2pd2XYA5vSCsRtfMjUeB6yeYypARm+VNLhchGj2whT1umaKuVJVj+VDgVcKHEbk4WA62pKsTG1fzNLTqR+
# DATA opVQE0EfCcFWneC3Ew5/gX2VyG1pi5SgOVwJ3DXy2CZ2ieVXQOOnUsaWhnhi4FopTxdSKm7KPrKRKMMkhVTkOCCNHRnhioJsoRvm
# DATA KcLstKwma+YTtqysZeeLzfwSWvtPnlQMQ2dxBDhvemoTdP6/81+d/eHsm7P/cfalYuR8efZn+v8X57/1zv4ZTBv64ef0729X0Tn/
# DATA lX74im76Cvcz/ObP5785+9KjL78zEJ2vKVC5zF8B2vnl+W8q3vnf0XP0DG4DPecbetMfGePzD/SDMHX+ePbV+a91ZP5Ct/xBQD2A
# DATA 7TiWzgswm0GnjONL1OH06c+iIJp9FCUUThoPtAlW8955NJ/I+DzhHjGSviEbx3PqLSaWN0J3jlhFnEe5zyCfCyWTiRqf6KVa5ncr
# DATA VAfLiSo81VIcWqc4v9E9yG2DddaVzM3hdfKqY26FSZdfLj8wEb1pc/f78p1H9Gsm7PC4pob1RG1uxWDqADs7Ftv1I3aw9h6x9YnC
# DATA qeQuRjZ+kXtwyGRRVDBMxzSecD6y3H62wEy1tFtZIzURhDmUEi9W+DoXV7/NDs01LetZYXYuTobj7DhL4CYsAQ3cuaIB8Io4N29t
# DATA 8L+RsX+nof+yI//tDPxSPVfzIWfwPH+t6yZgPFYOMIqn+Oo16V0FedDrpnO1kqgKj/IsxUsV+CaSrMlU3lQ8JYHtpePTxXjKocgB
# DATA E86gXRE8qsjyhUjqiCeMl1lipRYq6Qvk9kL5Z+WY3Cg8TjAqKNaMjjFeIHATHk7pQW0xqHN1h7m9IMQi+H5gRpyEs4XtFhskc8fY
# DATA cYwdx9i5ScbOrqPKTtOcXa3kWzb5r2LxX4fB72g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO46242g7jrbjaDuOtuNoO46242g7
# DATA jrbjaDuOtuNoO46242g7jrbjaDuOtvM80XaCVnhV2k5n1BoNXiDazura807MHc5dlXvYlenxu9rtgkJaq1nK9Wa7W+TmRFF3pMBG
# DATA ONxI0RtwoI02y4AMONRAgmGpDL/ZLkJ8GpTha9BInabXDOoe6DZ+qzfxu3UvaJeoPW2/1er2V0k5zYbX9Hs/8nvNcbN7HAStqd/x
# DATA vfqP/Hpj3OwcN/xiFAbBsNnvr0lEq1vPE+EHPZOIRjGAoBcMW6vEHspYr9kJxioXLXqOeWCFntO+Aj2Ha6xFz6HKX6DntJrd8Cr0
# DATA nNYwGvk5PacdtP3O0NBzBt3+aNjL6Tntdsvv3jw9R9XxKldjMy40hKCjh9vCTescVQ0eRyq945NKly2pwhpTazA+3Jm0U36bcnDb
# DATA ri0xMdRdOFpwPbgdO8RV3I6aaHaNsYoyPuSdHONwmJwc1D14N+qeLskCoIfb9eortNvdmOYdWT8p5HrppsJamQznJRjO4Yb9AKuj
# DATA laIkrfPUyrrtlpBVV6OGNt1Q8prRNPG72JWq+ozNFJ9CaV9gIxYyzy5MlRg9eYEV4ig7jrLjKDuOsuMoO46y4yg7jrLjKDuOsuMo
# DATA O46y82pRduKR2G9Y90CNf2x/k7pzV42YauCS3ypcF/cPn1iYnseSb8iMuxwMTh2ZYF6nJ4Df+ey111ffoSr1oR5Q1EtWb8xvUQc0
# DATA 6C62cw8VJOhDHOOSls+m/OSUT+fot5ajVPP+nToDbx1K44NnKGuqUCYKVX0D/fDdbSP+NWWFsZlNUnlxqrZ4tMjTTL3jZ6+9b528
# DATA M8mg7lKlQCa6pXM+7gi6O4K+8xH04oEwdxbdnUVfPTW4UW/zeTijXqrjhdZii9Ow548FaFGZs1wtRQnfxsMozAroFj4RDWVLkIt4
# DATA pMmoO5NzwlpJhbfSlU7L7noGnZPA+owYy1mcT0mC0qvgQp2LHl+fZRcRvzWHQdUuq1X9emW7ogryJ6UGr4TD9Y+5nrm5wtttIf8Z
# DATA cTgmenFmZfVmlXdjELM0unwuarxbd5ju035qRaEdFiUOd6JDk/tY3HWToLvqUjms76nPm++W4/WscsefNt/Jfa6SmR1Em++TfpvT
# DATA z5+2iMrLQVMt5y52qK3mjiFmi5Z7oSbAf27Luua/wFvPXZ2eB8gnneflPCuJbbJb3/QCYlVzzUuXnBv/8k//0aSjHHEr/+csUYo+
# DATA ZxLOc/1VtZTIe9LSJSQSYKMlLMUwgxI8a1FDrTSmWshQpnA+pzrJ+rrUMaP10SR2tpDj/9BjXUD/SOvQslY1L35okdkTqtzqsLjy
# DATA edktMz/5rJtGfrDaOM5wWSXF5Iw+ekkX2BfMNYXutUAAZdXWSxVRXlEvW0B//983F5Cu9FI876EYqCJnuoA+OUmojabUsXn6lF+m
# DATA TBDqk5YzeCJpSJrXvPdolIeRM02ORZCC0sCCAxA2OIq4W0UByf5hVU6RVrdQpfX0pWJScGvlYrqFyxbLP/7XzcWiuhgpFZEDHSQp
# DATA TUZMy5mpibBc5mlOnzVdWVdZPnnzEA1rKKaDKPiOqA9PTlQRFe1IlmZns7gwDlqX4wWM6KcvJTtFt1ZQeb986R7ut5tLSvfxUlSf
# DATA hunU491deRd3gmsCxxkeQwubSuaICobXL9DXRTLcz4YipRGxeix0pqMZIDhSAmo20I+Y3BEvRJMDu2Ptn5k68fTlkyfj1krnaUag
# DATA /+efdx+B3sIgG6UyJFg64FO2qyle6UNlaXOTCiesXh560yWNP5MwxT65OeSTkdHej8R4VAMMmUhgGEizQYk/fUkUovsiNJX/tGtT
# DATA eZCMFl4f1T5E6eTdGsb4PmXRFFo20IwZ0MiDyQErQofDn4bYn6NqfIbCStkej6fxBOcNkFNQqSBL/fNlLGo1UEFkYRUpQK0IfQ1N
# DATA pZCMKxVQ0QgUj6ZtBJorkt33Pky071FrCvHsQ/kEk1SojBigE+7EdcEq4Z+nYQe9GuIuDs7tXGlXcKU5z9kr4jm7LK/7uVB3LOy/
# DATA 3I7tljk3DaQLbNUki/KInVobyd3PqQrkCySadpE2tL3v8SYo3qut5NpZ3mtlRDcRvVdTrm4z6tjifMEkqOb5RhKbnUkV8R2JGuRJ
# DATA YhwXuZNJUfuUQ3gKKLeR+csLuuItM8GXQhaQgsHOCElCVtbCXlNrlD4318lcT/NKWuAfwtM1OwI0UADjottjpMAtZUENvlGaWQdG
# DATA ThRmdS4qaiuJeuwzIYt1IaWFeQ+sbw8bcaG3eVyoD7KZTTKLt6tCE3WWN3jRLtS5hRyuvUrGox2EMx+d+biz+WjXNbcO69Zhn9Jq
# DATA 3Gik3sw67AfC/bSVonPi4bMhVdwGJZz3/qB68bHBwjKn+inHa6tbV9YL84WkfHls09qivbxhr9Zsur/kaC8tJWx6quD+Lfi0Nz1R
# DATA dlOW3aybnit7z8pewY0rp4VS4E1WiCmq0zAecn2QhabvvqHlK1WxqHvBL5c9p8ISV+dMNem8vAiOQ+aav2dbVJ7m3lOnbttU4jLT
# DATA r96BIs6bCqanhQb04iLEsdC0YBLqHD19pizVZGK/JZrr8URmnGyCR3omZSCS1H7MatWSTQUKjZ7Bc2/rjgR9iz08e0oghCcAxmRX
# DATA T30KS1z6Hll3HIprmfeVU0wg3I0FGvXEnWS14PJ543qncV7X8r2F4HjqPopKulTCFzPAXx4r2YIDshRSMi2wAf+jgvh9c/Zn+vdP
# DATA Z18Bw/eVh2+M5fsGrL8/n30JKN8qHfC/n/2FiX+/V3d/dfa1x6DA35398fz/OvvD2Rfnv6Rn/6gC/VohBL8+/xWu0W/fnP/coy8g
# DATA EgoIEGRCxEGeA7CQuYF/cTDAF8HqL/Tdo+iEbAeeRM9DSNcqCAB69ekI8hF9SHZpDAh1fFiVva+wukmfmQeqe+7rTkv32cs5vwZN
# DATA iMMjI2Mg/pNosZxvRQDeh9SFN1xm2OxC7dkBAAv2vu4lbpv/t1osN0f/YwuLCSv5rYX6VuaZ34lOo3kckbWh739HXfCgMgSEdpJe
# DATA MwaQ1cMYCb1c8PivzmhRE3MkwF2L8PpRgNTXYBGc2vwsHqHTYRg8Q5yxXS5NHkFDJ+Kzy2LKw2BFLaTObbDAFoYlS//Lj5nafKL3
# DATA nuiKJi5VssSZcYNpXHw0W8EC7l4tN9s6Kw3vWcEBd0+MgwQ6C+H6LASNBrySYfBqOAFvzSi4AZtgJ5Pg0hbB7RoEUkXL2WHMgOem
# DATA Vd0EEtBKtVr+2hBFDRdj98XDU+8oDYfLUEH/snz1ATKGxTU2Rg0WFyVOZdMnluaP2fWEtTaWRczm0QAjvzHFdoIDmnGdlbkpwZns
# DATA o6MMHAFfxhWwmoyqqJzcz1IdqnlQscXx2VAsB/jomICn4qDYakj+PKVLGa+lqtJW5pssEnJk+UaTfTXvwwgAObkgm/YeLGGGpMny
# DATA aOwtZ1RMCznDzi/OHEbQYQQdRvAGMYI7D0M7TZIua1Df6hzhKlOE65whOKqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqg
# DATA owo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCj43VMGoEw1H/hWpgn43iJrhC0QVLK9A78QULMLzek0LntepG3he
# DATA p5ivw0HUHI7W0PfagU3fa+b0vXZvY97mBTP1610v8Due7ze9bsfrtap+K/D8pk/lRVeDjtftlrB8nXav2++uw/IVosz7MFfjSy+0
# DATA kId+x8S3VQRM1qP2oLPm+SAI8ucb9RyZ2N3t+Ya8UuVXK8jza7fnmy0r/g0rv3d8f6trIR+bjc5l3++37fL28/g3doy/XV+kbPnx
# DATA 5m6Ptzt28m3Y447ZL4+o5Ld7l31/MffqO7z+MpBIaSQaEil9mQWJHHTCYccvQiLNIwYSGdQb/VavAIkM+s1Ou5VDIgf1YX04MpDI
# DATA 5qDd7TZzSOTIH7a7oxuHRM7Qn1ezh6f5OoccoTyOrmHdIbBcHdrmYvvBvFZbhAXTR15GsxlM69fsYVEZbgdTg3ZR0b63QrHv1FbO
# DATA bsTKQkT1oofiIkoJ6ntUljzeNddqbYtq6NnZom7z9K6WYt7oWSv2yRccrSWg45YdCmo/gqSjmtEP0+gAopebKY0mHyql5G4x/cqF
# DATA XNlaXuxMMUUm9uBKNRHzKdglpzgER4F0FEhHgXQUSEeBdBRIR4F0FEhHgXQUSEeBdBTIV4wCuQpxnIZHd2HqUa+OM2aU5DvyVZ9k
# DATA QSYo5OIHtqIAWtXr9DTVhXexIXLP33/9s9f+zz/VmHh4f63OAD+zJ+GHczlsgDdSMPsmnADh/O8vJJy30OL5+NI0nC1HIev0y6ku
# DATA OY9IzXkuR99wqCoU5EL0iG7kw59kDmQ0tBUIiYUzOu70vTt9f8Hp+zVHuNxZfHcW/2nO4m/U47zRM/qiiJjwQeT8uLcMK981+pzP
# DATA Xj7mNrQ6ZbSDjKqJwogPyCqrc2863VeURN1CZ+wAyQX9dBCmWzMXjKJlp1VUkpzGM1n3qivVSV4FUnqT2G/Dv27mKZpB2a4ql423
# DATA FYiJun3NxD5orYt8YEW9W4h4vdbaHHUz3ttR1xdVPdobRkdpRFP1C1JghWVSYF8zKWivzf6Gnft+sCXzNyp06laCGi0dxIuqzmmN
# DATA uMxDpDtTac36iHvB7MO8abG+ydCrYhxZ75/mjdy+gUX2RT5fijvKFtKVyJOCZzRVIg+Db+6fCsqx0C9p3QHWr9ChUT9CRqAyEDHf
# DATA m4vZMIwx9+PHoCHMkhon4akMPFKcPPZnWljjaBnSiLOIIpYGV8IWn1MHR+YXjtYrUZA1MdpBwPPlO7BeGhWdZe0s6wss65LR5Kxq
# DATA Z1UXrOrNbKXnSfmq2ApCk19G/OqH4O8ZtSOsYudaR6wnA5d4xeg3Cbo4msbZnCVovE8MXYWNd9bNieCZO4mYzFrx9J4NjErRHMv4
# DATA KT2C+lO2qIsExxWxK3MfDf3vxkr6aJyk8c8SI3mjFPxDLwtH4OtEKRlFLMFkSiWbJ7lCOksUsWiUmkVEYXbKI+84mUYQ5eHZBNl9
# DATA FeFkiBQP7qXRmgbWGCYEd1YZ5RZWEZQaOLYqbJgyFGybYaTj/j6EeYodILZOKNUe8CDzDtHYRMtZyIYN1aua92Y8S1CH6BmN2dWG
# DATA wCx6tGBDkpdUkEGqH00yuK1UD6tMIKkCU36ZBQpdZ0ysTdvf2GCESXKkU/gxTjRLuUm1KszZYizIQv0jzsWKDHdBJLwmp0otn3v8
# DATA 7KHUtHzc0JsiRf41Y/3XEaTaORFakZShp4wL8/gsGHDbyN5Fti1RH4mcl7SK6FRJZmGknk+5C5M0iiqYyM/28/JgB2BunIYLIxiW
# DATA j0eUF1RhKY0y4VR6SpRl2OU6wf4Srso4QpPaFfo0g2+cY/OIAliQcRgPQYOteW8n3CQx/BllMojAKYNxhM4vtWKzQkBiy+pC3VcT
# DATA l36oCntpKeib9RTDJDVXZJA4lQtaZF9NzorP84/FqZdenCpMq+o8BVL9Wd6XMbFAam4OtVcy+0/1Pt+QJybhqUKHF02VjHrC631n
# DATA wEMo43qG8VT6n+t9A7Yp3vtQjx1I0zyaDeLJ9b6F93C/o1uQXkKze9DrfV9LABajyOwZoobHtuSMWlvxXXeWkxtj0L588ytHonVT
# DATA q90lg91E6qWfSF0WPft8SQibPb03wTAtZ/a1E0zXKB1fzC+dFAgKogHMbsiirvAWvO7zpaP8IkqI7ohb8Aoby7URnsutSr6YyUZt
# DATA ZXKcT3sr3hEUmvM5DWZhXogJMLZamXnogKbAtn6sqLZi0pQtSrPS3JtQ8iRo+1sEdAu1lqyX4+hiIWnUyWk41yCHncpgTYl+lEbs
# DATA US+oYWdRlmlW4StkuuWEq374MEoLeKv/dvYlqFPnPz/7s2JQ/YExV1+c/3vGVf0v7/zvgZk6+90q3Oo/g1bFQCpwrH5+/o/e2e/P
# DATA f3P2l7Mvz39NgX5V8c7+J93yJ/r+S3z3zr4xoYGatRl49Utwrei/jmn1IpBsqQ7jeTgbqIKxBHbIuGcZIsjainkkGMI1Ably1Tlh
# DATA TiYujRk7LbhfGikwz1AuJejjZH+tMPKo58jY07UVYfUmNtCinUToLBzAyjZApRO4bXpVuURujl0FSehh6b1rkVVcxcyNb3OFuxlY
# DATA FY16c7XpF7UUm4STYXjK+wipfjyMHLDqonK7dk7Vm2gGXALzKMVZUVasx3G8EQO25fSlR7Y7tEzUKoi1BU+v90Ms/yiNhnEEbzQY
# DATA BdSnRim8XflyiuoX4xmZQ0vJYW+6zKQ/EzPsVKjeg3gerVCsdqmpm+2ZUtN7VvSqXRLhuFXOCriyFaAxVVcY/F8Jz9MtDfzXPu7v
# DATA NOzvOurf1qAvlbGYejPIP6vGchP0qWISvXE0mcM6IcMDCGYTuTzB6fh0MZ5iRVaSfiBDLYTeccJlwR+Alka2yOoodZigGb1HBn54
# DATA TONkprMjFWkz3nqANdl0yVqKFP9pbLhA29lTancEPEwRlqgjPtMlAzHHfsNgLi4OyyBgPBGPBZmYEFW0/2HBvOB9gHoThUIB8UtY
# DATA QAGoKfoHeypg5+k18uUigTzUgEldDjDlAFMOMHVzgKmLxpGd5jK7m7q3aLVfxWi/HpvdkaQcScqRpBxJypGkHEnKkaQcScqRpBxJ
# DATA ypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJ6rkhSbUbzXbQuSJJajQatYaDF4gkVVx53okjZWdK
# DATA 0PYane7n1WbV73Y9v9WsBvWA/vqeT/80ex59LebQIOr2G61VHlSv4wWgPjU8v96dVv2A/mmqryUQFGVyfdBfB4LyexIwpT+mgVuj
# DATA jxoWeqnRaltFrzhIAiUqgquiZhi1opWINju+F3Qp2S3PbwTTRrfqN1vq20o8o35/tDaejdX6VW95zVZr3K77H/jNwGt2/XFL68VZ
# DATA DKxWM4jWBblaY9tNimnD/1GvOa17QatK//jdaUCvoWLp4nM16NKX1R9KL+12241gsOWll0EdSQvRqCNpbBbqqF/v+MGwiDoa8f9s
# DATA 1BF9DUf1Aupo5A9HfT9HHXX6lFWhQR0Nw0Gr18pRR91mq+63bhx1xDtMqmx62CwhFdni7NPHSOjJf6mZ25MBm2kkM4NtkB8eufI3
# DATA 70AfKjjh2sYJJ0tvq4AiK+xVhzyPsLJtjh6KHu4KJ9KWRlAOwLvEeL3lse2D90YIkVWCti/QExN6c3pKhdtBqXZU0RbzZ3NyHEnI
# DATA kYQcSciRhBxJyJGEHEnIkYQcSciRhBxJyJGEXnmS0EhxhPjoFSW4cnJ39B25ND4dyuohYD9k3FQy81MWskXJV0/N1dOIemR1WdOH
# DATA 3kW4TBAavU45dMR8oE8phnLxpAgiUr8/oOD552ztz+/NIIoEY4Hex/edrr3vk2QRTuR8H9/1QbgY19hvsDd6/eT17PVTdbPNGcpP
# DATA srij0u6odPGotHWuyR2YdgemN0v5PQcHqXEmdZRX8/DUC/F7Qd58wconUp9RAkYiHPWmgp8hmzeZJCfbz/pO40d8/HieJslInz+G
# DATA zrhpqDT+YivKMo2yp9A2pxExPUVSFpQlSJ8+bnnfy5ZzdKrRULXoODPkI7JsFNgopQEPtRNyepN4gUWchCYPGSthC8hkkC6n/UNo
# DATA w8QzPo+dmUPVIzh7j/n87qdw4RYUTFLWdBcF7WyQJPzEYDmHzLaca96moP0WbIj0VPbReTxE5UkbQWQdKoAIkkt1FkXDTHdnkt5s
# DATA kYq5TOU4TiZDPuuKmFNiaQ7McuAolRF+O6IoT05ZKNxkmyk7UdZhmXScSteq6JwGTOQmyQJJp0v95GTihZMs4YPBWyXC36XqzU1H
# DATA jm3TW6PUKjwWbO6ztcnZpW+OM32K/gR1Ed0zi/tMcL4X/XjNY0X1vCcfYENKBHn0eMInc3E2Pqt5b7FaM9ddTwNqUB0o8ggVqQ2H
# DATA 2AjEYZljiErVP1xcJOrOOcdxPqGBxOgKYjsqzr97OEqDl1HTCaf8OhrouHSUJPxguZDCxbaauToNLDrx5rw3rkxiReFCtfgZZOoZ
# DATA jpMZRfOHEp74VzhEMg0ndpbE5jx3mE6vpmv+pghRI+uo8V9a2ByN8LqVzT9G5qPwRnBOS+90A4LmOdtSBI9QFGyIerkewQ1omhtl
# DATA RjZqZqrtoZvFmHcDEuf3uds3tpJSk7g9JfCX5yB3HoibUbgZRXFGUa5SblrhphU7Tx82Tj9ublrxAFmR43AkOnpK8dxrA94GolQc
# DATA aXSZPV/e3tFFWEz9gOmwzIWczlG/CpC0vhnrmbv26Jbv6y/e3rcviqz9oIlw4WJO8eyui3OzZUW5tytBlf2NTCiZLHaIpbo9R7yq
# DATA 7wWTaiVqdmY2ioTULVETpyf9XPBK7hBJ/aCJpbmQ27W1zkURDbZFdCMIVeavGK2slvbi0lClqcVZUezIaJa+S30LtQ7vyMzFK167
# DATA +23P1FtvSiZ15jWa6p4T+Kdplk8T6egoRUfJT2lkFqbfws3iG7k74q9Kh01mpgZyGrNabTwwXR3eGD2SNRM9ZcAyGCb1CKskZcby
# DATA XFZfpgVsM2GVydOyCoFJfz4tkdip0weRVkHbgXL68tjejr7jbO/t3nxnaL+UhvZlKTvPWAiVdwDnG2RXDVAbQsOig6H2YBu9UEnC
# DATA ZgrNM5VPfSFkBfm/18w0Kgm9XjfRaEUqdy3PaAfxWmsfdS5hi28RhCuTcFQxBB22spbZWBlYpXqKneJSsmq3+Bvjxr130xjrNtil
# DATA yF5EugRGffwINgx7/+U8F9MO46K5QxNIzAKjdcsuSlVThExFn1QdZOAtXMrkKRowNC21PKrGajHRteP9AGtWiDnZd6WYi+yuWVSh
# DATA 2PH6hWkTojGql2UUgxTHybA921otYvlUXnrCWcQtEUaz3zG2fKxtljD9l+P7ACtBaoFOT5+jojhqWFzY4yWTiVn1ozgq+CRWILAI
# DATA tjmi9LJ1+frKaHda5CAy3Abg8FjsoP909uXZH8++Of/F2VeA/pz94fw3DPUBPegXzPD5Of0GutBvV+FBKw+f/fn8N8AN/eLsL+c/
# DATA P/vi7Pf046+ZQfR1xaNPX559XaUnvkLQHt/zDd1D7xC00EaYEIWOt3xBb6AbHVDo+beofwj9Ml4n5t5E0cJOK7IgiEvS0ardqWl0
# DATA BP6ylnOWhX9VX83gnrJoc4EyTb3xVobQW+NQVA0syXDHEbKsa9Ul3DZJaF253BxNiDcEjJO5ufFTdWE9U2gU5930u/HCeIKvmSYk
# DATA UGO2F8RXZBF9XnWO0C4ldu00ofuegNcBAq8ulv3IlLx48GPsoZ16shO85n2QUA2YGRAiFeIx9N4h6YE1AtbwgFkWqs0uIT5PZNNH
# DATA CvfhlHmM4qxj40tgjRCJLcODtlfJzUbMmnb2rNBB25PgoEFupL/MSK85QVcc4F8N19ltDe43MrbvNLRfbmS/+YFdquVqDuQbXW+v
# DATA tdwEKChPGUS0KIBsNc4LeNywWVNv/tPxXZq08yEnxonoAgQBJubfmW+CJTCmragtofyWaTij1GUm3ZJaE7xghqZz6sJmi52wQbCv
# DATA FjjIj3ygkEYp9Xb5oB/Lcr9e2EIwLCbHECNDAEojySqDRD4VoHLFGukTYH6SkaCL8SKqiN6DBZIds8cjHnnUqh4KDeWEOgrsGUQb
# DATA 5A0GKfJOO0QdPcjRgxw96AbpQbuNKTtCzS+2eW/ZeL+K7f60prtjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMH
# DATA OXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXbQc8MOiuqj+ii4IjvI7zYGrfoLxA5aXXfeiR90ZJLMuwiLrJlhKxqO6ptY
# DATA M/feGMQp7H8B+wSSEAX26bBIA8sb+L4iDBVub9ebF9xucX4obI/u8ei3qt+jv3X6t9f6Pl2f+L06XWt7gd+ka+1qp1cNmsG42fsg
# DATA ALCo0x13mlO/0ao2W+P2upg0g00RVwCjO0eFCtQMfESG3jCt+l79WBA9W7IxGvV77fWIpPpK9aQ4t4L6uN2sf4BUN3ut42Z92qw3
# DATA q806fSojiHphp99eF3RweRqQ1HlNA5LmY9GAKBmDTqNIA/I7jW6zZ9OAgnqz2xoWaEBBt9VohzkNqD8aNodDQwNqNTr9bpTTgEaj
# DATA wag7uGkakDJK1js+dFpLtpYaibBxrbrdCvHoZgw7+b1l8I+ZKK2bFGk3Gua6lWatyfyfgPk/q+tR7WKktHFjddNiu3BCKMfDtHqE
# DATA qTF4FvVhdFSx1t7tz17Qmz+qfKtRb3XafXb77Vc2h9S7ZFA6ytk8GlyWSqRtXngPV0wqa0Vu8+K4WgoXn3A1ox+m0cEwTB9uZg/l
# DATA OVyxo77Z5iiZvVKH2HZyJCFHEnIkIUcSciQhRxJyJCFHEnIkIUcSciQhRxJ6ZUlCivTziXWsKz/PXTzHVcbwCDdITnlTHmm6EHYE
# DATA oBmBzjOY1hjm81YyZQH0lUPefLwNS0miVhXioEoyU8fXtCBt8aCYtFGZyOmTFu6MszvjXDhq4446u6POVzzqvFF88GaOQL8bs9YF
# DATA n6VlF2T59Kw+Cv28yW3chh63GlxQdai+KslwpHJvML1Iotk8azqs/IoRae6u1eZu2SLNvl8vyjS3tkhd8+AHSRfVe/GFN8SWNSrK
# DATA ck8ucK0feiPhztSWkG7zcs/H1PcpvBDXkzfuJEokcM0Tbc4uGlu8O94ijR6yVuSFj7X4RbYZMIVBw/LJxWfvSGp2EKp+R9dPVFkP
# DATA VfbFVan+IAqzJUSjcbB2EKa5QPWDhUjyUU+SJAu5QY41Q9YnPILYM/xRJzRm1bwf8uA2iY6p0qADRKc6VWFzM1ZwmiQ1wkNpQuZk
# DATA zfuYFwDENJIHWG9RCfvRcHKKgqaCiBcF+WrAtArH9uUcqZcuccYbR65DHLCHhqMZz6EfSBYb1Vku/IxmZ8tsHon+IStmh7PlCANx
# DATA irmUBAgu0jAejXBl2Wc99RjjNAXG2J11tp4SIaAkLHYWuH5Zzvk6eWtnvlrmq7NXXwl79bLa1s9YsofXtfMF2O3a1vdpNGKjkQ1I
# DATA tmOzXIqCOQrZFo3r2xb7eSH0Lm5C1nq1Xl+7tPVaTaerylvni/7aHBOLQtk+EciiXOdyUWs2f07JpBGgJi8F0etq3puiG0SzJBGr
# DATA icIZTJRPISIkci8ZBjfGjArBkasbzCiyumIt/Ew2XEI2Dxl1D+kNmhhyuYrzAy3EYlSdjDv81VI8KeSMM4acMVTqU503z3nzin3n
# DATA RivqGQsaMg8Y4OJkMhGd/TKwW7WTMMsl/Greu8LpZitpnTxfQctvniaDaAgat0jRJenny0h8OU/D574fG6izofEuaATVTMBpvBDU
# DATA tIykHmu5cAyW3MiPwuURjZof0zCsaYEVDkDMElnuUXgHdBjhaASnGLtKcpenGaffm2G8Xwi/dqloEdG0Hw0hgjaM+imNyEJF5iGU
# DATA RQCxQ2krylpG/1yeUXDAIVUF+EFZU1CZBpm2LqAcB39NKs5SJT5NNsBwEvXDtOa9D/sJ0aRKSpkbKhDYMEQHAyRCfyLCa2MWxlsn
# DATA ZMgfM0u1UFyyGajXn1PBxyPovE0jrP3Fg60w8jGrWnPlmS3gwWEvsknyp4ByJKORd0RDlk6i7JP0JkvK1EEIxUaux8CrhyfhqTim
# DATA dDxVGWbarcPZx+MABaNiTvmSiQI3/Euswn2oZA0hhZnyyQJVcU11LoA1Fqg/zBvx+hSBaKPXWaWaRxoZWyATznzwXKgaglOmZZEZ
# DATA k1DiY5BJWP4pntDPFe2H4gTksJ1BmKanrNx4n/IsZL+dCkgI8wKP0xyf45Al+fJM+jCKOVXiJ1bql3DJHSXJ0HK3y1sTamg0Go6k
# DATA rRWL8Gqwb7TlU1Z9pD7mu5eGfSNu1w37Frs8lgau9AvjGcDx0fAGoN9vgnmv5ELV1pEbYHx/WlIhvZE3Mdz7fTQN6WNoXJNtOZkQ
# DATA c673bXwK6FNDScQK0TyMU+8hvMXhaupukij+ckx1LLhMEqbDI/jWbbzMf1EYmW8Y6gI6zJfe2Vdn/3z+8/PfrPJk/hvd94ez3wny
# DATA he9i8guoMN+c/Yk+fsEsma8qnuHLfHX2x7MvgKv5Cj9V9VNfefT1Cx0U3UYv/OX5rxRchuJx/vceM2Z+BzYNKDQOKvMCYBpnmtm1
# DATA 4oubRwkQ0GrkXojA9Ft6viZ+jyPeto1BTkHDWLuX5YVzcpcZ+Ch6eihczoZbKTP3+Zb8zY4xU5jNmZ7htikzq+Vyc4wZTqC563sQ
# DATA Eqe8nozK9w2h/WyAXtjvu0jD0+tEy1AbyMjGTkXAnGYasMZ4JoaCcHCZ7UV17VQZ0wkNYzLj+cSemDpkvuIpiNzHjzyuF97HvD1A
# DATA 3LZH2B+5blO5sA+h0a6VvlFms2jBmubY+0FjeLbCkNlW8zbbKStt6FnxY7ZF39Fj3JD+VEO6xslcaSR/NXyytzeK38AgvtMYvuMQ
# DATA ftMjuNTFcrLzbZPPsMXcBFKmnNCcLGM0J/KYU25GoULMwP3GcgPwdM2oSDNZrUUyDD9DhlWgJ47jlHExKCyNlaGUhxku4si4IQpj
# DATA NVQG1ktAZE5hbbFvV0I8km1mmCbQx/5EPG5HacTnASTb9VY35Vun0R9SCPz9Qh7JIcZ/zpLUshmKmJEodbAYB4txsJgbhMVcMGbs
# DATA hoS/0LK9VfP8SpzqpzLOHR/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFhHB/G8WEcH8bxYRwfxvFh
# DATA HB/G8WEcH8bxYZ4bPky70+w361fkw4xGo2A4eoH4MOU1553oMHa2NOqe3+qMG53GcdBrfp++F3Ok3+l0msPV7GwFnt+tU4Z2joNm
# DATA +/v0vfgc1c1uX3FZuCylrKTgToXDEhR0JZq9Yhk3m6WI9KNepxxgEDSuGuCw3gs67ZUAu8H1xrDR9K83hk2pOtcXQ7tQqCyvIQ+t
# DATA QrlkgBtK2SqUa4mhXSjXEkO7UK4lhnahNCTw62splwzw4pZyLTG0C+VaYmgXyrXEsFAoreb1tpRLBnhxS7mWGBYK5TpiWCiU64hh
# DATA K7Dacq9Yyn6jFKK6kKrcLw/+7ahRQnG1e82wuRaWtg461mo1LOiYhJ8aJJhlpOhQV/hpQevpAmh1e1YArd7lAygkodd+yiTsFsBl
# DATA eGZio2memZh7Fs8sbLabjajIMxvx/2yeGX3tRaMCzyzqDsP+MOeZdfrtdqtteGbD9sAPuznPrDtohsGN88yU10NtaDAzIXHGky3J
# DATA DgrLe6EXqc38rMsrlWsW/Yshlzlm34vIiI3DisSktBdlTXC2I5IXeYqhq3Xfi6Nhpi/rd8np22lyfBTttlTU2mVx2gq1vOps+0x0
# DATA HSm6nQOZyK+sHvoNa5FY3esHRS+Mrq68x3IcDpMTXojBilvd03XOytseOyx4Vmxmcxv20+lJrMrt+mYGmp2nF3g0rNwq1UmeLAcO
# DATA hOZAaA6E5kBoDoTmQGgOhOZAaA6E5kBoDoTmQGivNgjtsardMRXcXYUyw2dKdIWTpC7i6B4yQm4X1c271LFRndlD1Yrv1g/jN/iJ
# DATA w/j11/cf4yLfdhiP9k7iGVlXZIedzhfJd2HEfwwoxvRHHM7+Y92C5ncZtMYgkL1m0Gv22p2g177DUdr/Dv9RUejfhQ34Q5q9NwLp
# DATA eP39w2HyWN5RfsVef//wCctm7vV/XP/Jvbv0rv1DkXzDhW9z0K/7h08iMtaVFpwVF+G/cYB7Kh77dLdSH50vadRT3d4TiR4qx131
# DATA 80+TeLbHvRXlIPhwaAyvqx9lgXZvL6z0qTjC1/sVsh5zS16ldhLf3WjNTmIUzCS2K+RdaR5UbvQmSRvNHPFatvFlRoAD5Gj3c2wl
# DATA mA33JvH+oeRR8XdelaaJu+qK7/n1/eINGIJVfN7CvTU5PU2V7YlG1pmjn05ZxSmrrCqrmMPATl3FqatcUl1loyj2DaiufAw5Lq0A
# DATA MklY74M1u4zwyrMV8roNOh2bAnRVPEFeMuLEXIClUw/lPZL6XlCTXSHS+RaQrm3j6PwtMDo2X1D18QHzDxRFCUan7slhdPqhFUZc
# DATA W4J6JCbSZpYcj0nvwLt+0Z2+qAGTBXrRjayw+8lJNKFO9IJ7g7q6d0YmcOne3dF1XL3RyrlEX1hq3d9oRoOMRxlZD9HQSO0ZeR0y
# DATA sowsjpjvZakdJsntJtvDIjZelixTsHxHglOB/rZYjdBwyPl04rUgI3GmZHwoiaeeOnRvxGLonStqMePGPVv/h9LUoIKZ6EJhi8zO
# DATA TWujriqByU60uZdBMSQfS5zR6YzOVaMzty6c1emszuxCe/KZaf09YNQQR5Jd3ECOovobo9MAyabxIE0sCbwlW6hK/y6k1jUbgG6x
# DATA qn1nBsW8RanBUENKWEpukEynUTqI9RjIlmsaYaUFGxd21v7jlM3vPRBvVf8UPrMIu0wwjBqAkrB/aTDFXoo1+lvqvNuqiarcs6iJ
# DATA /EkZp8rm0D/mBpC5wgefgU6LOBwVP1luEMFBHfm1tqfx+YITpD4XLU/rDtNR2k+tGHZwmqItgDUl98Xb7EBtnL/NBtymuwYJiBvU
# DATA XI755rfyr5uf4UqEuz/Chy3WpQzM2sITF6ptkmCQ2GLeFUoYez6kQaujnTnSgTolw+5gj7Ws7qi8tPOihAPi3TCmnYszmGtTuuTb
# DATA g3/5+f/dNqkoR1vlrDLFlFQlVZB0cSrGGNl3PDKByaMtSR6EaNpXhd015Pmid384hDQePS0soAEaG9V+nigyPxnsFTzI5p+MjkxE
# DATA 0cRk2Kb0lpr3ZjjLqYCzoUxK5ad3QYTBSxp1GmQNJUgfO7lSvpZqzxWyt7k5ewt1UXIZ9rLY8JSQRTjR+XyfeTI0SMwrkmt6Ys25
# DATA FmITwCKeRjaUbT5Z8uyZ5pdLseiZgKQ8+t79eIq8GpG1lo0Bq2LTG5f8AF/nScYmes17B/BFvGYYZ4NlhgLikGRR8jpy2bS3y+bv
# DATA 5rxVLVfnKnp86noX+KDz9G3s7Qm9xv/5pwZYSUPKEywezMAzPwE+iOrWkvKOykKm+JnnU4H24LSQ9ZdBRHOQmvcRddk09b4vFVuq
# DATA LwhQzEni84oe3BuH3pv2HThDKO4SnkmrTV417/v0NeKKTOV/bRX5ylm8vYcoZPOnNNDSJIOCSHUeG3N2RA2/KnpOOQsM2oFUv1CZ
# DATA 5pKHsuKTSV8gd6OSwk8TKvQ4JoTy4IfQLsXJwIx1S0MTSDjTUKqKvIx+wxKKxI0z/SgWyVPwyI7jhFqIejiUnuf56Dzal+o8/u0y
# DATA 5pVPPXjrQpAMpvpLYxwqNldAtoG0YSTTIWS7l03iOeUnNw7uWwA64+lNn/VNtUcQCqoY1UWJlbsm7yhaSNFxFmIhMUumES4cLSPu
# DATA OPB0PJOJCvVLi2vpPm5+8HuLxyUwkWJTtU23KG6NxUkiHbJkLXrjTBCaIpQcxSmNbicIRddjlrGNjcIvTdfR9FPV8skWZFVnvJO6
# DATA JpxWpN76WE3uKGw8MU2wkMtzB/QUjJ2Q7gU2azlzi+aKLBvb5oq5Ipl1jxqYWuDVQsIyfoupaJmv1NzG3PCkUGoXsZ5eBpdLPtty
# DATA LhfncllDUHBelpffy7LRgfJcERUKRwVWR8qJzVrwJvECR5xZCYWRmKBYqtGEXTD5g3yehDP2WSMYnmet8ov4SdbBD1mV5KMv996g
# DATA jrTc3vTR98Lxuq6c5bPO5cuFcCLdYRknsXIkXdrvIEHtkLedzgY6KkrlMfe72WL2XB5rwBzWc/yF06NWYsbBvQdsk5sqAghyODs1
# DATA q1bfT06AQz5Vdee7Hl9YwjtFVtV3vbfo/og6UxhDMEJyS/i7mITFU65ws+xEZg8LbLTzeOmY9fdjRXTVbCrAaEOyzcDHhXYZGV79
# DATA 5FG0wosq1pZ3YwZmsgOSsmM5WFAipdhfhSUnm3OZMI/bplz+Z8ZS/g8gJ89/64FIefb7s6/PvlglXJbu/EsOvMT9Fe/8F3TtK/rv
# DATA N2dfe+e/Pv/l2Zd4Avd+hdv/KAhMuv2bs9+f/wfAKz368HO67U9yq+NYvgAmm5ex3z9VBxBNX49E8+Sce4KaJ7vlvWwpE1bZkM/c
# DATA WnmQGzDGDB5M2CMwk2nUCBNWbnDwk2FpYcyb57dQLN8UGTBBZTiEZdGEk0Z/2wDLUpHcHL0SdsCx1d2riscUdPmp/ISqguaJj1WV
# DATA RBWcwSN2rUBL3i0xDjP21wD9oxzlyoJxUMtdS/Da8Zb3YZceia1i2NEV7jaHcLBpQJDps8TQfjsejeIBNuRj27LsuIk0A1zfOoso
# DATA DPo5FXf/CtFypzq42Swptq5nxbXcKREOcOnG+qcY6zXe8vJD/Cviobml4f26R/edBvdLj+23NrRLtSxkQ465fGbt5iYgl4U0Ykoe
# DATA FhOGbaWSAAQ7nS9kKJyn6HrAqRuH/ZgX/haZLjV64ugICywPqRpkMo+neqyWuTHdlpHZjMCTmCoklr+E8JdB8S/dFXGJbDRMQEwb
# DATA KP4T6upxhg1rIArtqGPP215XsJKqJlULxoIsCHEsWSIFoSAPkQFY+cyq8yitslVHJbCcci97aJkJuBFRrpLBttFscAxMx8B0DMwb
# DATA YWDuPMDsNJO5hD18e6b9VSz7azLsHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPBMR0c08ExHRzTwTEdHNPB
# DATA MR0c08ExHRzTwTEdHNPBMZ8bOGbQbkTM3LoiHLMX9V4gOGZh5XknMqaFevNbOWWxUaSKdUoZ3pDfJceLyLJmt13vrMlwYDfbwbjZ
# DATA nFabTc/vjgV1ZoHHyjSyHDzWWIG+1a24lpBqK3GttzfFtd9vd1vhSlyDgOLabV9XXHtWXDvdrXFVMLu1cW32u/xrMa4Nv+4FVH+v
# DATA J66N7rXUgc6g2w79lbg269dZB5qda6kDw044bK/W12bvOutAq30tdaDT7vY7/ZW4trpPXwes4Ci0Zrszbjfqx377+90SHpc61EHr
# DATA ahA76ks1xE66ZQti12xTt9HdAWI3HLWKELtm1BzWc4hdq9NudVoGYjfoDqL+IIfYNXqtbie4cYgd9lBVZXVDj65Ni19n0eq6bHPm
# DATA 91+OS1d2ujbypda2OF05ZD6nspsvtb3Nl6rnhHmgq6syytespxmYKKgpV6+1QoeDTw0LTvKfBv9uuHDxjOqU1xUynFSGZpFOp2rN
# DATA Osre1YhxsmKgFnHXFoFx7ZX9BRthc1YJbLFNV2uM48s5vpzjyzm+nOPLOb6c48s5vpzjyzm+nOPLOb6c48sZvhyrNyqUHPs8KdHf
# DATA ka98eI++3tG/CmiOjc3PXntHHf8bmpOQOKzHJDNmsg2ieLLHoTNZTfQzs9pn9L/Z/QVuk2DVDwrApr4xHEaHO6QJt8cneNYEfqcc
# DATA CgdjPZrxiGBwZ04H0R2033zQ3h2wf4kP2F9W/fC5OXifO7a2qyGyyBufZp3RCEWWBQSWx/R9mxbisz2n/4KdWL1IfSd3VN6ENmJJ
# DATA heCahRHLOg4XqCLeV4AeFkOgXKU2lHFgRlrooyW8MbyDwTtaAgrWj5gNFlqq39A9oMk6xmnvXbqaQOReqx+KTBQjGpS6AtXbRAs4
# DATA y4lyrupKvAHZz2fKcQ69LxUCT6PORY/mMq1QKtNl1cOtSkqlJgfvtQ2/YNXtBwmNdGN1Wl02v2rx7Q9DyC0amf40OglTHKhXgqIn
# DATA 4USO5oeqgnoTJIQ5CexAj8NUhCkk8sXz0IuQRVJ/sFwgSeYQdFmjfDWOOpcNtWEmJcEUG+4gsAnDw5dhFBop9TBjlQYlrBUynoZP
# DATA q8eLLdF7D9SbS0QOvYiJmCWkoSsSBDAzKvwwVQCDZJIpHqOh6XAw6UPvBL0Qxxen7bdE8iN5zZpMfIVOrNuhOBvZ2chlG7lUq5ws
# DATA lZOluop1vNEavzG5qu/F3AbYSAiV0JNWsKEce2hpV92yJuJtwIHFucMQHFiPaYScg0rldjywfsz0TuZCTrht1i9CBDfqYsjuQAkW
# DATA rxOQvcbBxJfYJYSXXxBh/byJsLmQR7i1PsISRxVlvxzl+uY4s2vMrrqoWnv84jvimdq/MJuLFGb9PY9zsDbOratGWTvM6IYP1vvc
# DATA LohxHoCJtHXJyuu10bZiraqPjnSrEOeNQOQ3l/FkaI1o6C1eXC7yBzIMy+gezvnoDS9g67mUASdz78WnRJQ6lCR/TA9F4HHd90bR
# DATA Cbu02XG8MB5V6GCtEZI/Slmozoz/s+hYM6+MBNgPVb+uu0IA10Jg0bF/lg3ymvfvyFIY8ryHekarmyWzf4idQaK6phmZ4sqWjpQb
# DATA C6VI3symB6Z0NM0QDly82DRle4mNcHt0dUa4M8JXHNUr1pazw50dvs2sfn5kY9Vgp5sB+8DQFmwVeOB2aKwyrfA4H+qURGklVzHl
# DATA ocYInEKvE3urMOog8LlIdmJ4VU5EtLmRAFGyZSyYGTkMsklz9cr05Pyl3LAhgd9HpdCzCBqdh46fvAs/ecY+VDwh3tTNd4o7WaYQ
# DATA +LSFnKzdipbzDxTb55+gnOfGJTGSn2xGSOp8FYjk/YLnHi5tqjKA0qYRiqkETE2jI8ox459lP6wgseg/I8ydlfos1ciMb6TbZouY
# DATA JsyyAsFz5Zr3VpimpxBlTWZF93gaMrORrdZFeqq8xCzKij2QqUQMPvNkpv3kavJgN9J89Uc3kXx1yeyBlFF+S/JN/moVRbrAm325
# DATA YYZgnJqZyFOxQvOqfMlifmdzMetGoYrZOP3zJRnZa8E9hi7o99HFwsgJhcmaksWuVzkyC1kvWgCiFM1LLxJ4NklOJqciCZ2ysjE6
# DATA V4xFZqmHypw38KGDHJte8amKcHvSbq0QC73MJcvx4y0w47y/0i1W0CNKIjmNwGKlIWc2VGLgXJKaBJa302Ec0ixwygbqKFqc0ni6
# DATA RB7HynkV6pascGNmMs+LLjS65ny0zCzh0OD7CDNS9rmxBwwLhLEA1566bW5L6K2V65X74Ac798FUYRd0i9B1I2/G7O3s4elK/6vZ
# DATA NlKssGpEaJqNjHE0jbM5a19773OPGbKXYBKmR5CVhjLjLNOc+pMklf5V2op0rqMQiGS4Ba6lXa5P1fPfrX5/525VjV1kX0FeH0kN
# DATA 1UA1DDXB2jRJWfdGd5loY1HsUHhb+HQcxHFQlIpvHR/N4OqRiai2MOFYYWlwGJ3pPGW9eup1pZg5HtfR9nZI2AvRtb59qa5Vy7rD
# DATA MBmm4QkaCO9OmMQja6FaOdf0Hcp6iEJsC6XMgey92Du2PYMZDReWNnkGy0XNY5efWctW2wMGaThHnvORUL2fQnvInq5ct6bwSiV6
# DATA uwDvp/LQvvw+xRyBOYhotI8HWRGB+eX5z8++OPvT2Vfnv6bPvwDPEtjKP9GfX4Bjef5zfXEdFvObsz/S/788+/r8Hxh3ef53DMX8
# DATA kyAxOejf05VfMz/zayZneue/Ov97ADTPf8V0TAr77I/n/0hB/Ir+/pbeSSHgpl/QD3+gn+mef6aXfHX25/PfOEzmC+EoxbY0dFeq
# DATA W1Q1j4PODsQXxUNYn6YHFf5+hM3u8KIOgKxToJbjkD1XoZkiGJ9r6MELNxjXvHcezScwX6gzRWEh1sqgydWBt/Iz35rQ+CUtEfFz
# DATA BE3bh6r7jNsmaK4Uys0xNLlSmruwtZDX1JUHcIW4SVU7TsztD/irB9Gu5QQiYdcJ0IwziQq8h7KzMcKZ3xD8oNNo4eiZu5TdDZAz
# DATA eZWUV8vjKaa6CM1UANU9LSI+ojZAPeZj/d4HUZgt1fIt5dgSUCimK6DkqK80vueMOUPeIp5EymWdsr+cDKThcrKK09ytSm62dMpt
# DATA 7VkRNXdLh0NqOrvgJuwCzdq8ijnwSiyn3popcP2WwE6GwKXsgNszA6RelnLBxm0+b23qJjicpeRzouGmZnahiUwZvqkVivPMOYYT
# DATA Y6J4nPZBGs4tXno2yn85gE+/DZkhvhyNr8weRosB/N674jjzEd+yGChyWT78T8VOGGJfHlSjoFBD8fUkRD5ZU7AHeOGb4pYMq8qP
# DATA j3aeZbyPzOM9XGKLaKcijUpIrvijFK2TN0qw2yo0y2gOvenQmw69eSPozZ3Gmp2mQJcxmm9zCnCVGcB1TQAcetOhNx1606E3HXrT
# DATA oTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3nxv0ZqPVHLaDq6I326POqPsC
# DATA oTdLi887wTcp9JiGRW8gMmM9zsvBqdANe3nGBk3RoeJfgnaRX9gbjqLuai6DCRg0xn7Q+rza9Vq+F/ieX+/xn0ar2m16ZB9Xe41q
# DATA q9rpVf2g7QW9aifw/A59aRQLo93ttnqRvKMY56AZ5HGm9+Vxbgd5lIUsalWMVqMdraIsOz3Pb3XG3e6k6tcpep3PexTZdqMa0A/t
# DATA btX3u9VOtdWq+s1eqbb40SDyS8zDfjschcE65mFzXVKaEvuBinHHgjA2raQU6/iwOxj01xAZ/a7XCLqfd9vVJqWk0fPqlKau5wf1
# DATA z6tUFo0mpdD3SmjFMOo022vj1up28rhRwFY296yaUS/SIv3moNm+AqmRm54mNUortkiNFJdBbxdSY+EKSI1B1I2GFqkxbA87w5zU
# DATA 2BkGw9AiNfqtQbdx46RG7G2vbjNpaMC1fFxiG5uHtCVjQwmRypFfmhE3u9/28C+ZGh6bG3kQery1lhjlVzYnd/T6B1b81s4lOEQI
# DATA Cts+/zru5jmINk0PLQO84ApV5X45sKK4v3IoZClPWpQn9G9D/i2sVjVbBhvZaX17LeFRjEVKs8z58uVSawFrPcJxI6rxwsqg7cn1
# DATA tUAyJbCLb+dwSkXDs9jSZMhxIB0H0nEgHQfScSAdB9JxIB0H0nEgHQfScSAdB9JxIEchGvddvyo8Rdl0DPgjWTMa+fhAn3c/iZQ/
# DATA k3GPewoXiQt4QoJCVX0XG/32fEYyDqbCfiwEouaqVihy5eJgREQW4snqOL0ctffmcTSI9GlEnJGD/7CP8ihyIPOTN+50uDsdvvPp
# DATA 8PIRLXdQ3B0U3667/dwcIH8QP5ImVKHxaXaKJf9YDlna4Btz5NESTUWTmcihTjz7cPXUM46Ccs+rzk6PEIqczMzCSXRJ+Wyjaimu
# DATA R27idHMyhWvUPuftlLN3Uc7mHSVcFfFh833oL3Hbj+jvFs1sGhQXgj/8SD6+CHrZJg8uKRL55maRSJWbIhD5Jk5xjnCsG4NSrgeJ
# DATA zTIeWe5UVXAeHKfzwWWlKc8pBDwn8UhOMCcLpkBkPDTBBYVgvFFE9WgCg4gmLIkcPOaUaCLK02hnXjVL3toxS97RmqA0JusMeTOc
# DATA QFeAtXo5utSY+II5cy1LOCwr6o3gXaankVO8QMLzOjDnaGjGH2qCZP3FcjIfgc2uI2N0O7hkvvxoc75Ii1I1ZTlkyySvI7MwpTmp
# DATA N6M5rYd+hsGgkG7FggRkBnL4DywarlLRTAhlECTImCNCn+fo749PtXHzDOvIv9mxjnyULFnD4qfLozw/tNr0XKtPJ9MRNo0A00Cd
# DATA wBzTKzQIphkpjNGQTA0azAaUcZNxssSJt5r3CSYErK3ASgli1x1Nwp8ZoY6nVJ/Nu8JL5s9HW7RndacqOUTza2+uL0kOfZQmx6gD
# DATA lGaa3RxFBh3Lm+So0oTLAVQ47s+85QzJ1T0MBIIZiAos0wTK+5CK5sXlZ9huPt6x3XClVsotFrKWFRmmyRLq40soVUzEeEj5jCz8
# DATA /aBiDYe6Z4HScixdKZtlthBvKNWF+utyftyulO2rotCQm9luEu4m4TtPwt2M+yWfcW+cTD/Xkm28j8XsaBEqK+9qufcGNehyCev9
# DATA l0iu2VbXla2U1uZQuRBO+FtZ/mxlX6RUmEGCnUPystPZQMdEnTS+94OVbZV6kr+qLmc9xl84NYXxfVIgewE+wawXVhwbUvWkCbz2
# DATA L+QP8dFpHm6eU926F0nOaUdhW89sqZLqWzAczAaqLYbav/zTf9JmBL9yHIiUnViQ3iKaTHjqokATouj1PdifmXckVla4YFrEECps
# DATA NGMZL6d9XVyhl45PF+OpsmbZYOW5wVEsP4vlx2JkmDZD1MzS/PJ4zyNEupQ0coVyK41ywTmjBqhXoAUzlKMrTsJ0RVO3WKAMNTKG
# DATA IxOrXkFZLSsYZ7U5q21nq22lvrm1E7d2cgWLbaNxeJPiuwxoGikdfRZzR17zQnxBg/fZC8JvMwRwzs+z11pWlk7EVmTbcli4VljT
# DATA kKV+uvwu9b989puveHuD6UWge/2o6c7MBbPCIAdEysh4vwi6t5Hx9Zq/ef1FbSiwIyuXdomtedhEN79i4tu7zuiqjRf0+wda/3eR
# DATA LApVYu/bF0XbBGKinV+5IJvrVrwbW6OtzFezYCa7UnmVS6p8xFs8TFPILEQUati9N+RMsIqz2p5sO9XyS9L/xIKqmtPYrYzYOxLE
# DATA U8KfxLZilFbeBdiq1D/MzP4SND5j3H4gzlSj1MzI4ZNxPInyfiKGWu0Ce3VSlrw1Kx3UmqNcvJnlgdUKJ0xc2bgiW9/I1C1VAb3T
# DATA yhsqVJ/pDbR2MLpUq++hVC2ndD+2B+fhsJ70IJxBO3hOCYhxTjFM57zQy55joMjhrjwZR2LA5x0XUgahae7XeGGLjI6ap2B2SKER
# DATA ms6Wc+p6lH5wUVz6Duf7q2I9WxAunqPzHMLmcP0TM7i+PP+l8K5Azvrm7J8VmgtwLrC4vlglcP03uu0rALoErXX2P61w6BMDtv5I
# DATA 92jI1p/Pf3P2vwyl6+wLuvErftfvz/8DE7pw0sE7+93Zl2f/kypNOHHArRfC/mfj3tq6AVRgmgDvOkU/wfXN2DFMas0gT05dEqv3
# DATA Uc84E9XvE9YNl6ULLbtdUdzQIzT2cdhHPyWzdVHD5joDsfN+hBnCNtjWp3SXiZBDbRVM/7xnuG3aVqlUbo61JbRvw3/iLdnWW607
# DATA f5pRcesbixXsOhFboYCtNFxBLRBKYhxe64Liuna01kchGZ34mWLdqlfq9TqPGpQB1EXVvI9oADFWDxMseNI1DudYC9Y7/xdh/xCR
# DATA FBx1ZiAUKK7oEQ0EOFtQZmhdWN02mynFxvOs4FkXJsBxs9zwft3Du2ZmXX5UfzWcebc4ol/3gL7TeL7zcH4ro7nUxkLSbR/d89SG
# DATA boKRVUg4I34yxWy3k0mT7jBTi2ZDLJr1YZmH2ElcoYTGQPpQo4kpCZMYLKnZUL92FMYT+CsHIVhFzBYqJgujbWgyekoDnF5gjmfZ
# DATA HEmCi5RayK60rDxk1gzI5H0Uf6Y08Vb0MdU5uFfoIp8p59Pm7N+YYYWP57BLJkTNQ3HAJkNGZolZkJmz4pSiB6dkvD2Cpywehuok
# DATA eySGYZRhH2KcjbGOGcKrMRDuCtIVj7ABcTCOpqHHO9+ZwjXnscihtBxKy6G0bhCldeEYtNNUZ0fz+fZmAVeZBFzDHMChsxw6y6Gz
# DATA HDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrruUFnBc1mvXVldFZz
# DATA 1Bl1XiB0VmHVeSdwFmcsx6XHGSdoprpfkKNo+91ihjd6vc05Xm/0mqsgp17ASCoVlAWX6tS7vV5/HVyqIYEM4pQlqNTL2hZbqsHx
# DATA 5ANz3SJNathrdNrrnm+1dnq+1++1++ue7zZ3eb4b9TuhX86EadBseEHQrlLFbvW4egfTht+q+oHv8bWqXKv6fqPqNzvVTsfzu74d
# DATA NG8YLeG5usPusLcuBxkXVqr5nZ7XbPhU4fFqrz7u1UvBmbxbCa53BQQWNyGNwJLWaCGwGu12vxNcBYFVj3pRaCGwAgqokyOwgmF9
# DATA 2MwRWEG37bd7N4/AoplQlX7fadIeBDRWFv1WhZFGRjwdoscH5Az3SdtwyvjUCdYBpNq1si4Qbzl5XHKZWGPAyt1hyew3pnhXmeL5
# DATA A3rULs8D1835tJewy15CWR2En3DNYlu7mIjiQoDMET174qMMufwJMwyuWbErY7jWenx0RS16GDZBu4zzWEUHfmNr+sXfL8in4ova
# DATA SA77FQtbTzY/b8bpC16zYQq3GetlKvhOOK5tlXfztL5UmdfVyeXkwsklR8Fxvhzny3G+HOfLcb4c58txvhzny3G+HOfLcb4c5+sV
# DATA 43yhLqgT8tHw0KZ+LbBkyhmB1N2Vup4s00GECsK16jAesZGpGua9Vh0Gz2IMWME7aZogjm8rywvNi0we6qPTI+mTzWvvloxpa07A
# DATA JmwFk4uK0L+wrZHLYV+YYyYQ+k5dxWevsV0j5rn3bn70n+zo02xNX7B/+IRt9Md5bLDVchTPKDsU1YxlRJXuw7EV/FvofKi5wqVa
# DATA wTnGaShnqLjU8dY+9ijT/JJfZMVPCepSV4OTUB8mxj71TnBmUVmf9BtHkKo15z5O7VT1j/TLd7fZHVyGVD55uu7mKdt/XIiMiFGZ
# DATA OGiRRvUmnAZEPMTqP3xijPnPXjOB1xA3equ58Dr1VaCw0TVq7fkxyDtyo84NPntUTq9KrqlsW9sLp3Nd4e0WDE3m8HoKiO1lybM9
# DATA saEHi3RCU76//Vv5is2A9HX/r/9avtOjlKefvfYOIx5e23+8wfJWRjd1hdniAVvse1KoTuLeqSlcSU3BqSi83CoKl1W3f6bqCsYB
# DATA KykSsT5LyX0Rorrd+1DLcHNK+SDrEtKW8eaEvK3P7ufKAxJLPLTtwQfcbnmbFxaFNj5VyA4xFqy2lz91BzHVOoR8NHajwL0hMSkp
# DATA BGrV28XtnzuxiRfgcDX/95rJCUVRjOvmJpS1RtZSEy6rkvVpGivTLZ4xq5FsNxgzRiXL6ICwclkGC/gEQmbTpWg4nLKfumIE9KUy
# DATA qsrDFQWjZCaK9pamBzQOQrbok9GC4UppxG50JnAp4BYb+h4vDLLe+Cx6xD5epaxxIcfo5Tgnb0Jwxp0z7nYy7kpKOU4zy2lmXcKq
# DATA 22g63pSW1nsi2EQVW83llROBq3lO9rltxcbbELlXngWduTrpb+idGFpxXN8G1XTxlOEyO8sKAuuUkZMJe7QZgIC1Yh7d/houpkP0
# DATA afLpQF1QFrV8q8gfdour237sV4JK4yc0KOoYbZCUV041etd7/ImrbBFBbG4xfWv+0AoBOGBkw0ni8VaSLeDhphje4B6W7lwBBW8U
# DATA kzc+rLzqvLg68pjyiLyUspHWSZwtjcDZXFpNRUmY/ZvwOHwgXaxSMwNhRbtB0UxUPrDe28msqIUmqlkhIC22S07pY9GACdEzQSRN
# DATA TpUj1DR3KFyJABc9fYLTXTx0suaU5f6reaa4MCKSjbwcLJaKwjSJp7jIG40gWAWROKZdQLsr01EpVYR8KmKbyfnUQkqr6DrF3FKv
# DATA 8BvXoZrzmZpzsez8y2Gh5sOMM1GdibqTiWrbIs5AdQbqVsPzWYu9flhoJDMMdIt4mkOZHsgyKQugViwKoKTOe0fLIEJgEcd3OLvo
# DATA dzSVYcJjNXQ5WS00PKJ4YcvZ7NToQe6o4MrRNbEREhTVAgg6ikFAjZXafcT6lug81njr1InjNZaq7FFABeNPig6kLBn9Y25cmSss
# DATA PQHkfMThqNjJnhvTLW1mFZmNDwz9kc9Fu9K6w3SJ9lMrJiN2DmB0RMco98XbLEy0SO1L3nyXpWMrGEfzdUvIURYfcdrf5k9bbNci
# DATA G1x2EtgGi6KZbzIbC2WM3dXSWK8AYNe5cUkA++MnmwnskrFCYMckLtKMdOW0P9Uk9k+wZZRSni4z2e7FNXDG2qlKSBdzIJA59Qp0
# DATA jE0YITZQeP0lGbpKMTUe1Ly3YxZYXbLQrjeNM549yl4XbFdiiihvApFr3Fp5ZVhIDEAQ0etSxWd7arR9qQZdMoP/5R/+uDmHC7VR
# DATA MpolXdNIhH/hV40H8cIg7/mXnL7E2rdkVIuWajLXp+4XVNtS1vHF4dVFLPb5/REfCqe5wbQfHy3BfVSu34ru7gQVJfTHkIx9lvCN
# DATA h/ybTNivI0evWFen2W519cNwKlUBUtZ51kltwRQHCrayz1dUbaFTPYkWQGLJ7ibztMcYD/ReDPo4BVpWaF0zKAOiQZD1R9Gh3pOK
# DATA Qm1QMA3k2Ve/f3upyiesM449peLzZbSMdP69jxkcJm00gc6VmE/CmJ05fEEdN48AgH5bGiSvSUjFyfKKygEj60c4WsD5SRk4gwuJ
# DATA A1rIU8D0RqAo0lCJQruWqme69ktm5Htb6p4aJCQPyyuU3iINj2ncPKE06Mz8WB0lGCuB7FCqZUo2TDTMlFFAvdxsweA4hAW7ROYn
# DATA 1JBnpmdQveqUeo2M55IxJB6tZdUcLreIlZx7RPNfrcIN2++Z5usnu+brJ0zgs5arcL4xb91qOSyNjrAfXA6IUEIyNWRgtMnV643k
# DATA eca+itwyjEYjzmG7Hwj7GYtX0wyN3Ttyj6rO6E3F6ovR2f5UdrOWMrRoJMieRdtIMFcke8iu1bsL9cSOnS1q1x91RINxAv2sEP5S
# DATA KkldEK/EwpuN0aOSiGyC3n8+++b8786+PPtfZ38+/y24d+e/ABKP/vvN2e/OfyNovN+ffXH+87Ov8Pfsz2dfnf92lahnh8OsvF8w
# DATA jQ/PfnP+azx19jVdZN6eoPfo7588uuXL83+g5/5y/kvg9BCDfhqdVA167+vzX9Hf3+JnJu79yaH1XgRvjdQ0mzcvU86HMVrpTLYF
# DATA g9jwQ+ObEeV7mGNkMQyh9MOWgqxv4PeHejtJGg3iubK5siX6I27t04TF+reS9N6SeFkNyMH0bC8Ncue2OXqrZXJzKD2pOvlK4sdS
# DATA lUTypHwzeiJrzTE6uRFaNu+onqtDF5QVMmHE26bRbOl4ejuU2bUj9cSs576cux54mcVv1icDQvduYs9zN/ZJ3i1RdU1OFNRHE85Z
# DATA Z03Qv3zoAIUWT6c4owOYEBW2gRFfqv5twQCXG9WzQuxdnAjH2HPj/FOO8xqpd6Xh/RVZgLmVof0GRvadBvbLjOu3M6xLlSzngIXW
# DATA e5ZN5yZIeuWk6kURcamGLDdZGhEze0hE/FfGxIpAsWRxVtZYRcniOFokc34myvhAe0Lm0mKcDLNdMHkfIw9lGascI8peeAh44y4l
# DATA fxpjg0lCVhn2bMlAn1cXemeYLVOAwUIWGKVMZn9+Rbvt0wjth1N0yiUjOjhCAoRjhUl1ujJk4URwXwM4qzXPzNHwHA3P0fBukIa3
# DATA y+ix01xlV2P3Vu32q5jt12G1Oyqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkqnqPiOSqeo+I5Kp6j4jkq
# DATA nqPiOSqeo+I5Kp6j4j03VLxWO+g3Olel4o1GvWj4AlHxyivPO4HxCtS3Rs+ixjXqDUN98zudIjduNOj2VN5QBGMaWU0QjTyIZrOe
# DATA l00gtD05PBX0CuF1msGgMVgpqKDle0EQjINO/dhvNj+vtr2eX/UbLa8X0J96tYsv1V6wpuRW0XytgEJr1cfN9uedjtfxq02qB37z
# DATA AuqcCWwFExd01mZA1yL3UeStytlo5RnQKLz3W81B0G7UV6LcaNc9v+V/XqW0Nqm2VDv+tNWkuH9eDXr6ypUT4AdXAN1xq9CgO2lg
# DATA Fuiu02w0ms0dQHfDUbsIuguHvUEzB9112q1eu2VAd8POoN63QHcdv+E3O7cAukOTqm63NzweXqxby3y470XUC8RhRQIuLeatoOIa
# DATA vGCWL5cVg1Z2y4qTSufQiiOy5O+3w1rngb/UoOqx763OhpN6Ri2BrU26cauuRtKY5UWEnApb0HXrtwqUiXarmLW1OWMGPr36Vd9G
# DATA g9uhFtyUKeLQbg7t5tBuDu3m0G4O7ebQbg7t5tBuDu3m0G4O7faKod1smJskmw9s3RWQ2hCn3F7b/4584yVHxnIp5FmyCCdyP1rU
# DATA 6x+Ei3GNZ5J7fHH/dcoBHEel9ygn2hwaM8s5375XeMcd+UY/ZtyLLJJ3sR1vz7dD+VQOk1mBlN9ZCoafXTlypgliMgU0RzrcIWp3
# DATA iHrdIerSMR93nNodp77sceotwrc3dcxaWgHbwdBrl1VWc8z6GQp53AZ1YaiOZ6uaga/e3tG+krTVzW7GDoxcAF49lfdN6nvOLCiy
# DATA GKYxC9C1FLaBff+y6IQtFrwWVfM3C9/KeAopZjOsoRhwqFry/4Lo6udNfM0FE2G/vS7CXSvCwe7x5UEVlDaOB0eTrlwQSfVQrtur
# DATA vhc4ECsx9K0Ydu0IFqO3kffwlmpRkRENenFxD2+xlcfDGAO8MDnRB5LfG0FlE30IH8PPeKBD28vILJlX2KdJrXQCr//k1IOSJipZ
# DATA DF6eGEXirRc6l9Q6PjdOzVCFOKQgKECYOWMd4CCB0aNC0sfBmT/BNTnKFlh35ykVSzBN2SK2RABwGpwVGHkZdYiTZJ6s3RzaYgAw
# DATA 2dD7Zck00h3R+zR7OcYMacwADG7fA+wOVglCtPO+5mJAw8tzsNhBYp0lu92SdXbrS263XhYK+8zlgXjB3FoIXjX6JgVJQKb+ZCy6
# DATA rfgHfT5GClNkK0P1masKvSAKHDeBTV1RQLpucuoaNan18NTdlBBL9Q9ZbdMUWET6zRRpVcM6q7bnCtK8p0dPhJaZwKk0P5VtsQjz
# DATA rOFpQdIl9LBRYjlV9hkqGH3IImUoITCpSUUDRaGT3+UbjFFSluDmOH/MYq8S5YiyWMf4PTNRi3kOSFEVPaNFnFZYmZ1jo1XZCxaa
# DATA Vry38QFskCIosgJwBGNLtD/Cwtz2WD8AdEXFmrcpRUMd8Xe0xNWQZreIDSWBc6/CU76Kd4rNsqLqhB5jkRxFULGqeZZRnbCy6NRj
# DATA UIGivmyKrn7haoxfIQEbu09ylqazNNdZmoVxynlMncf0IgP12QtTSgwypayYJsmUVeq4QeTylJOJNJW1Iok1Vc8r4qyoyGAE3Tk0
# DATA I6xPMxWMPSuerN6pdsXLiJejgL3LVoJSd5Q2qZYbOUz0fHPGbsIFHE6wgUEEsh0UbBcomFhctmm16U7j52a6i/6y+X6t0sm5qj5v
# DATA vlvLeBbNj+cfI5bn3yU5Lv6B396MctGFISiXH8wi6kzm7Fqs4siitgyxvuG3vCN7JSNo1umCciN+GikCGU1BsFVuclohux17f/tU
# DATA L0b4usB4iZCxhyTDmoec6si4h4CxdRJmY9FS1RY6XZpMsuvg4NxK/n1yknD+DWmcmhdzr1Ev5l6za+XeA16oQbK5r1WZBMVSAJ0X
# DATA LEcp0phyl/iFJxHwRdis66lDuCJUeg25VWiDl8+w1uYMsxq05Nn3qE+l2L2b8lR2LhOYPN+CUq1rdFpWvi1gSvEyGRtO8Wy5wJAD
# DATA 0dJJcWLFIwbDeqjm0exKUfDMJOwYOxonz0HetS+Rd2+hCqQiK5GvDxayr1TtGkG9lH0VnkqziXokRZHRPFWUUkHsk9aI/ejDNDzB
# DATA Vl69NMB6s/nSwNPkmd2HXzLLPticX/looBB+ycNQW9c6k95lToVwI4DuE3rhMdkcxkwnC/chNbyJQjsNWXV4mgyZ5OeNsQ7sfSxC
# DATA wcy0whWzfGJWZTIa6CnXWZMXLfo6ss0ezC5d04LNGZcPjJJxxjFQNNB0Hj7AVeV1mXl+l2rYUOdV6DXavGeIKiq2BbILgaZLyhEj
# DATA thtj5LmuJd7RMlZ8L+bGKu8Nm4285fx5RXi9LA6JHOM1iheQmLU5Xv/v2Vfnvzz789mXYGx95Z394ez3Z1+d/Y+zLxm99eUqsOu/
# DATA 0E+/O/sGjK3zf49bPEFynf3l7I/009fnvzj/zf/P3ts1uXGc+Z5zrU9R9oSju00ARAEovJBqaimKepmRZB6StvaspVUUgEKjRAAF
# DATA oYButmVFyNbMmZkYx3HE7kRsxMTZndg4F3uzFxp7dCzLluZiv0D3V5hPss//eTKzsvDW6Fc2yZRNEihUZeV7Pvlk5v9XQDgUJoX1
# DATA Hf32R+/47/BTke74hn7/Nb/pm6Pv6M1fH3/BeDAguxQB7Nf09Y8UIP3kmF3Pg0slg/qhyxzaPCDpQ9IYPlBqkhoXOJl1pqx+Lx0K
# DATA ZVg0FfjiPqZ/8VBckNJu4ULt4fQ5OABQKOGnwGHkjai83bOjNPKTcLAW43UfK+Pd8NDE1HG8bF+L6iCuGuS1pFQuj+SlamG2ZPRI
# DATA VctBTPGcHM7fL7VR3/xOrpJeJMwLLkMVE9HCl535kY6XA3ptVnQXzvR6FGWgg4wFMQEkVXdZhsrBJeel6G2wF0hkhBmqYE4Rw/Nz
# DATA iK8l7+24q2fH1LvJ9FqcUyqlC2SvkyvjantmsZU9K7TXyalwaC9nDly8OaBpX2ezAl6K1ZarsgAuwwDYaPw/5fB/NaO/VMyFXLCg
# DATA X9esUV0GB2wh+YCaYm0oZc77+pQVuAZC9YqTMJ/Od6ZqawRvgWCRkDicmDfpoDjlsuCE4lSug43IYI/Z1wt/EDbgpHC9RZNwUFCW
# DATA HA1ocXeG4ou6XIww1iZUQ3gNuZthnjjC2hQwO0ZgHlCg4vKAc4raOFwz8ahIWcwgdo+si2k8irSjipfPEDqWoWG2FMRmoReLHWJA
# DATA UI4S5ihhjhJ2eZSwDYecjeZAm5rOVzsNOMss4CImAY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZI
# DATA YY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGHXhhRWa1e7/POZSGGNXtBrP0eksIWl541QYXa++IFX9Zv9oN6ao03VqXdsRstoU9Wm
# DATA 5BCXkZRBjRUphZTl+zmlnvmyq/h24dVz+W/emQs9aPmXGHqrngVea+UCl1RlgfvVug0BywXe6jXb7d584PWgdeGh50BvNWGxCaTM
# DATA r2egt6CZCyAKwrBZXWgW9Ljn+839WjCoND2/cQKBbHWdaJwBQMaNTQPIpN3mAGRB2KpvACDLXQGALOh2euUMQFbvBFGzbABknV6n
# DATA 0o0sAFlQ67Ralw4g0w10LXyq5AeaQpa734yOeoEg2IQ2lg9C88ayflzn1IIj03q0jUWZJc9suixQqisLpGI7HiqlJWvCPhtEuTfn
# DATA PApiGeA5nr8Yb5IfkJ0Ak2qJR7JiPJKSKfPLLEsW+oKFF1Ru67kW9d5+ZpfMRb/J9twyLlqr1crT0LDKvJpSliu3wlxZrLF28jfO
# DATA +R6M+9BhyByGzGHIHIbMYcgchsxhyByGzGHIHIbMYcgchuwlw5ChLlAo3UFUiHiZqLtbLrDTnT+NyeyO0t2ff1SAQ3U/2mULtoCO
# DATA 9gF+2kWVvG0qNJ8ug3U02d75LO5ty0M7n+mgqYXCBAlHnag0Igt1p6heddsO/jarOuuDG9sSvZ3b6Ao+3HqcHWPrCk7sc2uOg32E
# DATA +v1Sijj2sea9SD89RUllJQ+aGE+2VW8FfWJJPyVg1L2xO1a799Mfw7C7TelD4K/Sbzuf8dO749t8JoPiRD/+gK9RPJamJpdgk/W3
# DATA TYbfllqHCT03+qyGUZ6/qfSdKe8VEk6f/DHKz95jHJLKn7+cUPSZ4EH5ESeSfWLL3/589euY9NaJ4sH2NiW1iDTv3GTTFpA3lSUU
# DATA E0qyqRfUkDj1JXbj7nyWVRjrssTdvo8yzubiZTVIxRK5KjmkxoKdz7IMQ9GhOGPKxvhVRc5jSTekM75xQ99cGs/INPlMxfyW3IlT
# DATA dnRfgSNCE+sPcOruP774J3WmEdi8+Ia/Q10MRWIh+KK/syZsHI+0w36I45K8/LEY+udZXfhc1RGeTOo2uViV1QO3c7X/ttSzXcxg
# DATA ddWzbihUgnK+RU1mI5ESFkIfVwduZXThtXUGbtbm1VMTnCE96SkuX7u7sGp+lgNz/cy6JvEQKqtZe1CJQlR0kswccEm0+AxKPKD5
# DATA kOlTdQ00j8lYsZOLNAV7EI9ourgsUKyk0UPRXCY5ZozTmTijzoTTl3jx9SVOS5K5DroTvLKS89evx8m8h0PwIHJAfFUfnA738Kpp
# DATA MkwmNDNby5S5jqIVz88R7ssgzSxqbFw0amaZiMkZWTNebolIqjSvsN3xy1oaWDCbRk6MXqZugYCn1JNM5MMWen9CVllBXE+iZY/I
# DATA G8tbVvOSMWaRgOsJ66E/m0xZ6itW7x3TyD8S/YRESX0YEfs1Qh8nKY++QEf0cw3HmVDOhNrQhJrrX51olxPtsobflcbXdRDzen0W
# DATA g6mVl60yUl5viS6U3ZQw8oyjBA3toJ/kRihBCOgBrOTdhYgNio41dUKZCyv4WPSEmmM4iHtQvIHoNpwPIiE1iqKuxoydlp9iIqqA
# DATA D0pOG9LqhSVKWg6esgk8ZZhI0bHevfq8DogyYTeaSODL59V3Y7ePcLPv8afVd2pzR/GF+PPzgE6xc++UKvlNGI6rdfKzssixLNir
# DATA p8XxeVaUjWwYvybJbK+fNYZPGPbOEh4alzQbkfHIWlTZhmm05/0kZm2rDpuHnj5BD6txxmJzY5bvhbFJcdiLphdBGThH/gWny783
# DATA ovSJx852Cy0AbVwFdzLpZck4cYWnzDO0TYeDcPCE8krLB3J4uG02AKabUY1eNOIyYPE2nILwurOJFtelQepimBZZMzwtnKGyPt+y
# DATA Vi359jqN8bLvj5k6s9jUPmVbUZ2LopVChlg9GoFlIXnJ0nSymJAqeleUTkveXzMQI+r0R/Gns8goKFIlpQkdWAnTPqYd/ZBrIvJ1
# DATA qiruBeRm1k2dNi9PqIO615Oc/IDqDqsgaqlmgyE1mURp5CrEFqpCjRokPFm4nSeQgpwzZVXuhSy7qJB/g0hNMjnblYacEfXu5Yfh
# DATA Z9WC66drwa+HA7Yj1FQhslk0MA44Q9LZGBMwSmA4aR+quUFHdBZlp3PJ45Ua5C7LkU8U241yrRdFEFHEVIssiigdR52YibCifjk5
# DATA ZD1DMwkfRQcXkYP22HfaClhen4XZUKpgK6hcE3NRU3Bp2jXkrg2dvSL1mGlYJwSVhzLqgAxsmOrYQeH1ySJE/UKWsQooCx9SpYYO
# DATA 5D62iqk9NtcWqvICuTayIJxfw/k1NvRr5Guac2s4t8YZ14RWukAuTaNcVdkc/RWmOFVz49145qyMdd4NZjKu5NjzRm9e5sDub3Vy
# DATA UV8zk17e1WCPnOaKnvVyLmXnI7EzhL4lvZ6YBmFX7IKcQ4J3tdDPbCOZXmdbbU/ZUX4R3cJHvKEfr5BIqadNz6i/m3l+VY5vYhiY
# DATA kHFPxgufucPFYfhU7ijLOblozEfzVvtOeJMMp8Qq042jqp42UdXfTVQrJ0bVb24cVdn2g8jyp5Pipm/PYmeumPjVlkXPt6JXWRM7
# DATA tSpo/FlyLoCnf+Dt3eR9ikMyseVGNj8mwzuvirRCloU4FmLXwexSrs6NaXCfynHcmxJEVpGNb8ZqH+bSCgeOmEQ0GexapnZO4f8/
# DATA k23a0RNUmpj3MEoakI5MGQ5CGt4B2xnTo2SgYQamqEDZLFYDKRWdUE22hJJq9v5aSEsMycmgyDBL3rFFb+mCh5kITRRelILXjX/x
# DATA ixhDCrtXRrMUgvzpIdm+yTDNvKh2zPrRYHzCwvFcqWaLx7ZfNVsGlvyXPVv0+AN8yEr8TIHJVi5plNHUqj5iw3KJvRxWucU6nE3I
# DATA JiaTzqYd/jeGF34N2mCeQXj8G/y9SDv856OvmEf4p6Pvj37vHf/N8ZdH3x19e/xf6Mnv6ZPiFjLjEMRCCZxD9hiI+BUwisdf0A2/
# DATA O/4Heuhb3Pb90b9ROPrJ3x99D1ziN4xBpCAd8/B5mGGY6pVNLLjCg3iCHKVnCspfyR2ORmKwcJKhO0uEySJ6QKUoNAIYVobgQT2p
# DATA NnrGcdSh2fg6uOFDvY2BBgBGqzm0oTWZ0AV21XDDhVK5PLShqiP6NnA2NHGHf1m4H9tXrA73UdJTe1ouHG3IEciBDeOUK7vDGm5W
# DATA bBeONbz/dDxALxNqZ8gw6c4GIcjryZQ1e0reB+j7ue/K9nnx4hc2xtOzZv8TxWE25J4ylW1QcKEk01CvZYUjQccsAA1ProKrrZb5
# DATA lvWscIYnp8HhDN1If46RXnMLzzLAvxyewisb3C9+bN9oaD/lyH41A7tUy7k8sJiFz6rlXAaccC6VWAEACUhx/uKOlVh9znE+QaG4
# DATA NBVUDrQ1vYk6RfHw5mvZVqwlumEljdgrOp9vGxIJjZc1i106TTq84sjjsUbFMT+Oa0mX5tqj1EQ/mk0SLxwy/o2H/IjMhrgTY2k8
# DATA ZxPkLIDoKQ4WI/BuBG+U2lGt1grJeqDifC8KU0SIbbvOFK4YMRLZqyOUOllbV0Xdnh1K/XK0QkcrdLTCy6IVbjjUbDS12dQyvkob
# DATA /ywm/kVY+I5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXo
# DATA WIXXhlUY+LVa0DkjqzDq9vyo8RyxCucWnk9NKgx8r+qX94ut1qd+o1hteI2A/u5Xg8qntZZX8eoVr9rYb7VyudTx29VObx5jR2HV
# DATA l2LsagtkQznpJwC/Vh7gF1T9OYJfrZmVtRxbywh+UTMKO4vgRIsP2AxywVeqrXzwrerK0E0yc6HXysGa0IMzhW6XSNP3arXGfq01
# DATA pK61WGvt11ob57S/CCNs+F7gN/r1IJgLpRN02u3OUhTl6bGD0m40dlCaoIUdrHeDZqN7InYw7LV79Rx2sEt/dysWdrBbDxqBwQ62
# DATA O51au2ZhBytBrVm9dOyg2aYG4f+9jebra7h9Yt96C3aRNsfn3mYGSjX1eiui7iYOCxK/pQDDQK3EVRZofVhYXHjBnNvdNhp1geTn
# DATA 3WTueT7sAK8uf+ww2TrdOIcCbTohU8TIzQd1J5w3VCxsYD6y9uYCPaKrZa/yMm+vLKbkk1aB75P/Un/sGfd64uBcthbm82SN2bI2
# DATA yWxPOOCgAw464KADDjrgoAMOOuCgAw464KADDjrgoAMOvmTAQZvvJskWL4aQ0vioOKK/8+Nm+UalXKCZpfrpgItwR6ZsGvN1Xw7J
# DATA 8EE3NLIb/Cu4dJ0hAo68/+//8FplfOtG0bj0If03Am2Nwr2zW37tw60PWEudz9HxQg0CoR8liBJPeSjCEpY5fIO4eO1D3Mt0vLCd
# DATA IsQd8xQ+8bvesY+ySeq8KJ3Cjxzd8v7j1/8vIrOQ9u1qpXxDrrK4J7oGBKlRZg4h5s52n3S2253pftHPdJ+WFHYdznrPudjWY8Le
# DATA RdMwT5S891DtbW2XpXCwZ3o6/Pk5GnkZFLD5w+wXzQBblAQ4KwEs76/VZ/XfZWqXVAR5TS8yujZvwPUYet2EfkgP+Iz2AzghUbVY
# DATA CqgfxpOS9yiesvtJC75LBRTh8tlYjierws0d3w8zKaMxRBuTHp9FzkRz5hRuFsr5SQRTOTRyO7CJrl7p5hmdgrVakDOGnDE0bwwt
# DATA 9KhO9MaJ3pxkRl0PMZwHUl+ZaNFNDP7ik6RtFHEeGu0Gaobx3kiRv5SGmsJHTmhY6EDcooebRUkiDYFfhXtU43F4Qz7Ld4gODdyQ
# DATA A1u7ZYlmysbgr8dQnYF/LFOysXkw7LsQ1Q6H+9oM90VJgT6JSvqUW81q2Be7HUUWmj+uvpe353LP8pg/PQ/wLisvTsldebSGn6Rz
# DATA VYgr99AqqHTFthLgyuODRMSakhkEY0LIsQhkZYiWoiUSUcND9kKJLJOYhzSu7cOL/AvIs0yGefUiUSki2y/JxrsQgjBUO0LRqO+x
# DATA oazPnEqjUbOD5cLOiwLQZuFNbJIsgSbHtJQDxgYsKHPG0AOWIPT5+FdnLrmHG5fcQzlgLla6Lrp3YYugIwyZDUDFsafUv1MmfUVj
# DATA VsdRLKE8OgzFx5I+ovZNRSCT1LuazwiPodoXxb3pIJoqsMBExSUdJ9PzF1kuZVdXZllvcsoy+8k6Wpnql6TMfgIBIuRjO6EI2YAo
# DATA libS6yha0GxPGFmUu9SJ42LSI2vE8LR60YFoTunBbSqS8LhTFne4pA+Y/sbMFdPouPTbs/Tw/KWVT9NzUFzvb1xc74cAt/NiBvX1
# DATA GY8q7YuWvmkM1OvtwR/+JDoUa78dQkHL6ydDaViYHIw4NNaoG3lUUBPQwoDKAa+KHfC9+Kng4xiakBXmvPDb+Qstn7IrK7RsFD5l
# DATA mT1eXWZ6PFe9oigH4lpWXuKPwD58DAPUhFJhBQ7EEcPyyB01TrA3zrvL5dtjfBd1QhAhw7gnlieOTXnjGR+eY/GEEdAuF9DvZXG/
# DATA /iVS2bRE3o+Uch2Gj6n6SREu5XxQpAcYaU5ibYhQX+Lx8S60gEMRJBQwoGo13L/xzBoBwOzmoSxOtZGC0hX9uwtoM4sJOVMxXS1h
# DATA 7lwYk5fBz2YF4RxtztE272izq5TzsTkf2xkXG1f65C5JcFqm5DLTwwiIyg0b07jYniHU4JLIczlPlt57AnufN1lj+anJ+2Z4Jqx+
# DATA PwF0loViuivrUkaNOwl1Vt+Qw3agvWUG3MXzArVrb7szPBFwJwFkgDv13QLcLcXG+XJZg+PKG0PuZDcP3IX4IIwxoSBDpZjzas6B
# DATA qB7IvIc6hAWfXaPM2C9sa/cOsJDJ+4sa5dVePt/nRx5HT9ETda2n6Jc1j9X4sbfp7kP7mVp5jZtwJaJOm6bYTUuW2vT5hdTZrruD
# DATA PoXifUKW5yg6LNmSz0rXWToBOIQOEs/nlhZOFCxOb1gb0zRJme5YdabOguKE6RUP3BS0cceLQ4P7FvHYK3e/VtfmF6ttZx4DLqnA
# DATA qpUy1zurhVMfNdPwS7Unt5OvqdCbVjLsFIpWYS+Qhf9Uur4RxXEgU0VWzR7PJgC9y8J2krJ+qiWQvQFE7gUxnjOEHPUiUWcS9qYW
# DATA Qu49fa14/LdH3x//6vjXgMgd/X4RHfcvS/Fv9OVreurL4y+Of4XLHv3zNV38Hf/9FcBxdOXbo6+O/84g4b45+loppEPhawztVBqy
# DATA HSbu2pv6bJmHnqkz3l+F+6F3vxvLWSwRvVf7Snj225vE0ahLHQh/O0gmg66x/uH5no3FdwpXgrjOBodM103g0haKKDsNsgUK1fPg
# DATA qegpNbTuWoTc6xDQYK0Jj/8WnoTjyGUzAtMpXDVHbnnRXB5Mrk/RYXJBBqfm+qqvnwSTuxeKJPhlAOV48xXZjvQvjQniusJojgbj
# DATA gHKbFd2FA+Ukz0I2c0bo3GReZaZT2rBRk6mhdFBkueiKwgt8NLyh32Vre28WUqOYRtS3vRGnTwqwfujpew9+6qXjSJEycPyd0qZU
# DATA YWZsA8G1ON2ANre8jq42cZa2weuCnVueGIeec9bDJVkPGkt3ZqPhpXAhXp3BcEn2wkbmwimthaszFqSSLssMYyhcz4Z2GRQ7KxsA
# DATA msMicTcag0NFpowZqE0O8Wx+RbZ0kuFwhu4aC3jvYAbRYYcFS4qklC+dyB7xJxE7KMT7hwxL1WZ7GumpyPh6L57wKdo03ZhwB5BW
# DATA qnyzGiZGGbJPFuFE/Bzq1x7NlWM+4MA7gt5LPqERzePkdSgDk9605D3U8ZYDCgoWNu8EXrBb5KyARpAZTQsmmSE/oIsD6eA+ZXLc
# DATA Ee8xp30k7hreyxmNmKODE/JoXQCRqSpBueqYd45555h3l8i823D0OtPBrnVm+ZXPNC7Co3rWeYYD4DkAngPgOQCeA+A5AJ4D4DkA
# DATA ngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQCeA+A5AJ4D4DkAngPgOQDetQHgVfxqt1o5OwCv+lwB8JatQG9EwbN4
# DATA cZUMRyen0bJ8b8wplAbNXHbVglYjiObIapUKFUBtDVnNenXrzK9uVtqVevXsr67Uz/zqarPRrnXP/upq9cyvrlda1Vrj7K+ulZ9Z
# DATA Wdcaz6ysg9ozK+u6/8zKOteuW82rzPBcuz7dq8+b4bl2fbpXnzfDc+36dK8+d+MqP7OyzrXrqy3rXLu+2rLOteurLWu7XVeC+lVm
# DATA uN2uT/nq82a43a5P+erzZrjdrk/56nM3rvIzK2u7XV9xWdvt+orL2m7XV1zWdruu+rUrNRVaZ371eTPcbtenfPV5M9xu16d89bkb
# DATA V/mZlbXdrq+4rO12fcVlbbfrKylr2/VQKXvVRqUf1Mv7jeBt+pp3OjTa9aDWWfpYrdbgx6r1xcdqcHQ0TmOOqQmIBZf367kg/Wa1
# DATA WlmMSVAOvEoQ9CvlYTXwyv1KeS432kEUtBtLkezNM9HUqxlNXfw5Fk29WQ6joJ6nqfutql8JcjT1Ob46aOrtqNXpZTT1oFKv19qG
# DATA ph622r2wnNHUa37QqZQvnabOzuBimzfpG0+nLLZrLHrmbW2Kw9p+Zh6Ibpbili276Y0aDd6gie2ZzERf3O1Yh59VXsMHwTbbllG3
# DATA tmWsBLpboa5nrUtxKadlYJZddI3gYwn9sJsc3GrRj/hT9lQpfl6iVw3hAluxBFtZCG59HmYBemqrqd6/JstW5tfxkt0Haq1X1zCz
# DATA DKD2gmae7sLciYL88nZ5NWzdLqk17vBldY2d3OxXd1B1B1V3UHUHVXdQdQdVd1B1B1V3UHUHVXdQdQdVf8mg6pnFqLQbtneMfUep
# DATA 9h6K9kcm/HFbiFXcZbOtPDhkXLmIihSHSTfaFXQFXZRttmjU2TURmSjCBtmtBEE94KuY5YlsWrqr2eg8NVaIc/UbGqUGpCNicEFM
# DATA Icy225TA46GCjWS/1OUFybSLkLkw8QXVnNtGKaWhOtouF+q1HRhHOKiyffPnH6r/bu3+5Q/w74SD+ejmXoHK1eK0c9l6i3B6qArs
# DATA frYfjuLBILxVKYwHM5r2p7eqBUjG3Qo+/zlHhaexJi4faTz9o9neXpTKuMgCZN7Du+/dMtj4ThQPtvGGG/PZ8+OS32Sa/Fvx6wKt
# DATA f53lfzId3rlQJAARwKFJPoLQ/PhxLFB5v1TRQaJzViwRjAoieAFNPRE65BeqOgNNvCnk+aZkLusaJEpCkGxRQHrOhExDlq6+ts6c
# DATA 4gyOeyss2c/MRAMSaXPytPR0Vsl3bmNkgeNqTiMHYh8qAVBysSVvOMYyEPywkBfocDp1TqfuNDp1c2IuTrHOKdYt0fxZzbK4Lkp2
# DATA 3niCdsoaWvk4GSm7u3lJt70ZpHEhzLRKu02BLUbgzcadWAWN+R2rsWqxKqbRzkvS5dFaC3J05r5+5c4DDE3UteiIizdcy039TMZt
# DATA pZiWka9gAydMqAcGEKgbLOMUWUV/ygL1ElwKLV9Pxnw91b0NsVhoTSm1OSC2POtJxnlC2YriHEEbn5ISw7jWHEI+8pf0ODrRU0DU
# DATA RNYLPZV5mEaqVUp9nO43lF3EcnuZ0q0aGnX6HxlDytOGFBTrgPcRpWKaDwv1ROVQzDoWJe9nGDkXHun0Z9At1vpjylwpeTxpyA20
# DATA ggcWAKp4ags5qnBmUZBxCYU+6bnRxzJmJUaEGVRMrzJnCdJ1OXJXdfGSI6pX58ZicmOajBXbgOtKMmE1OaifpbMxRmhsOYaeM9W1
# DATA TtS1+v9p+ETgCrAK2Z7B5Gt8qApVDy7hQXiYWVQyAEns4av2HkfsyNRxY7BraJliDCK2hxyuW/F0XbL5/XjbJwllWhuDYch1juYN
# DATA OuHvwoPiWba9VgVkGlReL1BoqCzaRVHCwtaYS46l5MIudeGxIdsoQTmdAJGh0/AnPcHIBOU064YBnWHWyoypxlQ7bcqpbKA+Z5Ac
# DATA std3HrImymAvvsBZNuo4A9UZqKcxUJ05+vKYoyvNzGsurGwv8C8izAY5O1VaDP097fOABFtFWajZI6zXo1BY11V++flSEz0J6GBt
# DATA 5RDcHG+RufMqddDzLVUfR8tt8mqW5zZ5qaNm4YC/LWsvi8fEpPV3Eril5I2Ho46OjlJfuvOThVNm7MEnm2eFkLf1LH/hdM1BwPRG
# DATA Gq2V/bqyGftaeZrzRxtjbLAtF29WVpmWB2Zex2xs2ZKGwUmDPexRPV0wmK+8gZk3Ry0H3xy+Yr4uvD6LUfMX9balUiwQu04kfIzU
# DATA iwsUkUlEpkvYJqtbAT7m2jtOv0pT0ATgfvXOo6EAvyk3DQ2Zmxtr+YaKiLyfn7WwDDio7+MoGQ+ohX7A6x7Ii2z+wWpmirgoMsk5
# DATA nfC84TgNUXE16M1Yi/NIaY6yKj0dXTX5M8Y+Zg+6PBUzTWYY2AkhM07GkmCWoroqVdprIvZgQkZkZ7o+Yvd4vcFLYfEf6uipizKT
# DATA ZgvcC1GVOI+QkwcTVs1ODkY0ZaOf4iHk0HVlXRqbezLZW4zNSyhS7LjJzoo/qxU/X+Wcn9n5mc9twK+cLlyen9nwxOd5HAardi0x
# DATA X1fBX9Yrv/TD/adj2bfDq+BkykTJLNW+1hN4xlkwpt+zLhmAb/MkALO/MdDYGP0fcDeIiOUBxvqGjLFspgnzXGG1yo7flON+NYNY
# DATA rcPLNI8/rr4Xpc5mG/vt1zCKF1PGa+kmdfjGiAllmG+/Fb9+ImLaCiafB/qiiWftpGIJTsGZ5lV/Bf2jqMoF7Amh9kqZsD7S5nEL
# DATA O62vZLzpk6Jb3TS2vJEj68CG1DFQ3zEXR+zOsVHj026eMy7fTezueilZTHqZxo7qBkzq+xqVzB3EJOI1C+2Zfn4B1WatQDrgQTgb
# DATA 0XwICwLpNM+oNunvAk7DZhevEViUIfTsE5CZgZCWXqbk3cXl/ZjsHXuRjC2h6GlHrWZ4sh6hjjr0FDUTGzxCAdgcptiwxrMOnrGJ
# DATA EcVrFcpQmoSxojeBJR2OpaeeK8/MgaJ6x2wTSS5jLfeIQfIscpGzYpc8msMxLeEw8QrbPIiJmVbdJBJ8lJr5eeBEHaCSUWYwMrQz
# DATA VXgfMwqdzMl+0WZNFjB7lsYdeHnixEJmH/234y+P/nD8j6BaH/3p+DdH3x19dfxbD+xs+uHfjr45/u0iPfufjr4/+jPd9/dH3x3/
# DATA lu4++gM9/O9076+Of1Pw6NP39OTvj74//jUo2ghaSNq/or+/OfqGOdpf0CP/SreApP1Hj+4Cr/s3FOw3FOxXeProdxStP/KTFMTv
# DATA 6O/vgOU+/sLRta//hJA6sWQYFUGWE0SW5k5xX9WhZgoQ3oCXgXm1/IEaIUJt0xYECcbOKTLjxoNI8cIU7Yp6v4mG2jMbLDNa11K0
# DATA H+Ih6oMih87Ozfey7uGq4dlWiVweMVvVqtSa6fEFrpjp/N3tKMy669fpC1fGdkRj/UWisilcZlfHeiRTWysWJnUvKSt7g0K7cFL2
# DATA vX4CnfoQEHMaU0fafqUMZreTIkpyb0LltrAHXHy+ZLFQJ7UfDW4jrn3eJkX2XWp7qcJUekO9OeU09W+1BZO1pmfFvj4x8g577Yb1
# DATA cw7rGm99utH85fDcXuFIfpED+Ubj+KmG8SsZxaUmmqRnu32faVO5DEC1SaNsD12VPO68lceHy7kgOykpDXsslRFO+5KGHjZC9mXJ
# DATA VlafaXoeCpl20j+c9odZgVl7IUOdGwpZjKF4EyL1+4lnoivgXc1c5tiMEk9azXI4b8m7yz+yQHcqZGJWdJYlLNWrIqB0mozJ2uor
# DATA Cu40bCPD5ICdWA9Zqgwgm/KrE6eiT6GztANnhONLO76040tfIl96oyFlo/nKhobv1djuZzHdL8BydyBpB5J2IGkHknYgaQeSdiBp
# DATA B5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHkr42IOlapRoGwRlB0r1qr9wLniOQtFlx
# DATA 3ogebecHXKxB0K+XK/vVavlt+v6L+XyMgtYSvFXT85u1flCr7zeBt2rmH+v43UbXn39s6NcCr0KPVstFv+FVqvTBqzaLtZpXpf/T
# DATA b41i06tVPcCz/GK1ydcquD3wqi2v6uNuXC57La/WLFZ8+628EzLPtqp2g7BeXsa2WlI3AsSnse9X5gFt7Xrbb3eWhVJbgPHZlLRq
# DATA Hhks4VoAr3pWfat5knkUBo32Qgwrlfr5Y1jxq1kMg+oFx7DVuoAYNutZDBv1i41htVE5fwyr3CQuqZRr1EjOHcNatXJ5pRz4zfPH
# DATA MCgHl1fKQcu/gBg2mhdcyqcB6ckgpEF6Mp5ZIL1WLfCrrTxIbx6bx1fCeZBer9uKggykVw+DqNE0IL1Oo92lOboB6bXIOq42Lx2k
# DATA x9s/i+us+1J1jk/3ufXQIosu5xLym/lZj84EtrHgsqW8x6bH7WKlG+3t5EKeI/S9FdG4HocFifu887vKrm9Z8mY43/z6vQqZJ2ub
# DATA rqmVtPnO/tyqlXQE4+mNRznL3TgWcMRA+8KxMax4yiWg2jIHNPvhrPCUF2wRz6dqU740UBiWV6KB5ZXl26EWXlFCrMlmtWb5ZKLq
# DATA xmCXMFnFQae1GrqXlXDBLpM1s4jF2qaSa1Uj5exeXzg8FUCtXzmNygrqdPNRBwF0EEAHAXQQQAcBdBBABwF0EEAHAXQQQAcBdBDA
# DATA lwwCiLqgJoq7bJ0WQhz6LEDCd1JgGbbybckPPh22K7Ul7v6vu/ixiNpymwMR8YhdNbyprxS3n5cLlUKtUKc+Mu7N95Dqtp0d/bi5
# DATA +za/zlTE7VEhBv9tpLu9XfWE1evt3B6tzSUA5PSIlcVPvUdGyae7d57qN0hPRleUnftUdWf0H+h19hxjjKNj2zuf5XLyNh8C1rYi
# DATA Z+jOXKpGu3coQXz8EsYoz9vR/PgcHJJQkpOfCvNHQXOvpCB4O2zO5aehH26p837oKLJauUujLkvIyiljqo/CwHsoh46RhDF1sIy5
# DATA MwmbssUL5N4P1Nt3xPJfXjYnpGSa7O0NcikpxNTOUYskSRzoz/H9I1MECqiY7HKt1LZ/2oHOI5K7U9jL/fQWTSKoYic0ZEWUMaPO
# DATA oRQav4beVn7Nb5ZvVavl23ulPboXxuLPcMNdNuq3cWqhoAKUbei4vKPvjp6OkxEE28LBw3A4fpzkny37i8/eKJXriBAlZERFtL2H
# DATA wPQXuRtKevGIVzZxJ3ugtuVTMt5eFmKDikkK8IFkJgsmAu64jQ83fGY2Jj2vyUXKide//Kh5m+virjWRQUkXqmWswAkAEm6UhOva
# DATA 52pOwsr4GsGoq8NnWd2/rarG57oN8BR4iu1GXIR37+0exCOaWJX4VDnXy6fTX/5SXTyI2k/iqf2T9Bb3dqZ9Gqe9+5MJ1245km6N
# DATA 00gfZ5HUg1/+EvPBu/coQuFBGNPsj7MP/fQQ4+SSynzKVpSMrUYk/aM0lNuf82zfzhMpI4lz3rxYPL4uokeiwAPpQznF3Y68iKZp
# DATA um1Sv2Omsku6Oj4fFw9oWpfr9FBk5jEZ8nasWFKgqhSWBIk1fnrEBGU9x1n7mrR6CUZ8auZQrdOycVo2y7Rs8getnaiNE7XZVNRm
# DATA pQD5ZYnd3Me6C4+uUJsYRbZsixa+eXYCalehMi6mAF1+jA/eNoojvTmMR7NpdJKOtX7WdE7mgpFcVqrh85LQsjdEaUJX1klY62O+
# DATA FG0+rgvF+EN0WZzfCQtnUOnwAlpfVpq4OCkAuT+fMWY9ycoJ8yObpbxkLXnDU6Ay35nPCO3BybLC3JolnR/059St17/L3/xdfj6b
# DATA 8WDlVO+qbP6uSu5d/GD1VO+qbv6uau5d/GDtVO+qbf6u2oLU+p3gVO8KNn9XkHsXP1g/1bvqm7+rnnsXP9g41bsam7+rsaD/fqdp
# DATA 3qX1VUwbXqmubk9fXwAxdT1UCNJFKxFZow31fU8ErYSjMzSVkw5MRkjMHoBN5kn6EFJLk1yXJyH4Ba9a8AIejhqgaEUjFlL1sIOA
# DATA gxag8NCQwKyI0UC13H/qoX9lmIEl+2W87ZmqFA1TmDdoRTAMgghTrMbT64FtIGX+/IsJOWirmzqtnzq5mdKLOVM6LYj1mcuC8uau
# DATA bJ/XZSA8LfnNC+Z22uKlS2GdK3GyrCHIJw9NSxUuCmTG12Blr4E46nMiFrihvLmX7RzUxpV4LfV8WU7sUO7QZBoqmlBJMobWXaXQ
# DATA Gk5Y5AqOUTKG8DSZVWRfMf+U115ErHUs03je2gUdRszTeVdTAQ+ogsqUG3lCT4UUD+gd+9iJKFSgPbDJWH6SXs6MHOjyaTH00+ci
# DATA zD7WjJzTjr1KyfRnYynlqqUzlpyxtMxYynVVzs380ruZVxpZz15TXdd8qs4hy0ofwgMwovt4M1KmsT6eoGlCBniuke3NaH7MruZJ
# DATA pDSwF+S9qbkYBXBLGTxRU3yuQ3OO5ZzVsCiibu6jcVU3Yx6RqHSNvjKGzaTX88L9JO7y6ucoiVN2iU+0prZ0Bxl4PEuYVnQreY9o
# DATA iPZ6FJqIqKe8TipHiTH4DiQuKe9fRCCHRgucepZZO6VGP5uK4cYycmB+dzURDjEuee8pnW1vGHcmybjPDhiFj4vCDrvl8TzlAHSr
# DATA 0X0t98Rn7p6QbY2RUoPXmfIomooZkWbSz4MEG1mmoPnKBrxxyFBDq9vTAL2SdxeZSUHH47ECbyMIdsnd9rCwjauM3g7lLrvMPZyR
# DATA QF88Qu5o9Lukm1PlHdDbeGV8TfLeD2HXCLd4LzGq87jK5haVBMxiKWCNnadSl0o+TYbJZJIcKH1vqf68Sq6Lhqu+J5k4wr7OZNaB
# DATA Bgxj0MV3lR3izdImDHcDTaeiwsCnKMvr0vMmy/OzZwwLPAuAnAFZdDwFiWAtigWqFOETDFJTHsL6ZDLYhiW1SUwa2NRLxTSk23s4
# DATA oY6mYMZBqQ7AIQomAC96EjF8HjWPsnEohcTkabIs91CVByDRU2RmIwzMWFNKxul8IsWeOokU9LrUc165QnwkRyUXZvMeYUSbB5vc
# DATA Rlqr1y1qxzGGuZVe5XVO5PxCiSmFNZmX+ZX5led8rS+vpV+kWZnGd7Gv4eUSaTQZC0uYBdyILvZtvGDykEvWVNYpOh2rE0ZLudi3
# DATA 8tIJ9n2vbpj5F96cDc7pi39xZz8Z4pLe1k2SSWrzLf/l6PvjvwWQ8vgfmTv5KyZcfnH826P/AaLk0TdHXy8CLv+FCZbAU37hHX2L
# DATA fxhm+e3RN8d/6zH68ovjv6c/XwrhUgVML2Ks5XcU+NdHf9b0SgZj0m3fgnL59fE/0G9/dAjL6z9veyQzrUkCI4lNYSwaJbO9/pQZ
# DATA OSIzrYbXQTyFuoacIjYTsdlI2y5kSmHUCxneKgM+WzCpzNyAQYFZGPIZ1LX8yke844L6wnjgfUIWIxtRjmSZzeF0L3DVGMulBXN5
# DATA QEuul6k1f9TVVJBH+ZtRWc2tD1TNxfB2kTRLMlZZSEGtYcpeE2oSY0ey3KC0LhxkeVdtrRpQ8zgsHoSDJxmpicxq8HaA/1HJgq3b
# DATA CXHciEbZCeTZFF4n7GKEMNCoURSRkY8FeKqXhzw3UBQknJ8fL5AsT6h5q82SZc3pWREtT0iE41m6Mf48Y7yGWZ51aH8pXLNXNqxf
# DATA zqi+0aB+mjH9CoZ0qZdLcsAM6M+w/VwG4XJJUj2ah9InZs+FaplUkotYFnidM0S2xx2Ms0gxJ3dZlHnjs3p4kggoUPqmNtbNOb4h
# DATA x22UQ+1tArfMOboRJZUMo/3J7m5s9fMOaI6NNWBRPkiFCuj9NM1MKBn5yXLDLu8exSyGISBownjEa0uGdglrJ5YXKM8wCo0Xsu5a
# DATA aEjlW+1GNEYOYzIbDvoRxyL02DThDXa9yNEuHe3S0S4vkXa5yRCz0ZRmI5v4qs37s1j35zbuHfLSIS8d8tIhLx3y0iEvHfLSIS8d
# DATA 8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhLx3y0iEvHfLSIS8d8tIhL68N8rJSq4VB/azIy2bUaveeI+TlkpXn08Iv
# DATA axWvVq97lG+eXy0P/HLg+Y3yu7VG02s0B5Vmxas257iWdG97EYc59FtVr0IZHfjFJv3d8lr1Yi0o+n6xQuEHv3iv5lPYzWBQrxb9
# DATA csNrNjy/0igGdEutWKXXt4qVoFhtzJVJEDXa3UU+YJWi3fjUD8rFoOxVmr5XntaqTa+832i+Xavmw6h3mt1GZTGMZs0LauVPi5Vy
# DATA o9ikSFVqRZ/ygmIUIKbFZuMEsqaJ3AJHz2/K6zrxBLOlDhd/nSPhdbhofam5EwEV5uLbDZq1Wu0MtDyuv5qWJ03BouW160FU9Teg
# DATA 5dW7UY6WFzW6Qaud0fKCXh22taHlVdu1ZiWj5TUbNd+PLp2Wx9W+uN4wYO/+nG+aigpnLz+3AtC2QY6dJolexLmpfF30/+EPtfDb
# DATA J60hLDd2VsHfrFieTOGzIXvy4Okge7VFyF4WzCkge9oBuTKP7JxWGaowdqr+2R6jCttpbAyYQWzFNgI9dqsFrvJq9l2WrwU7q9aY
# DATA EyfkhCHaOficg885+JyDzzn4nIPPOficg885+JyDzzn4nIPPvUTwOU4bTiMUtc1DaXxt3YDGCCLJIZYbWtqfeoY+ht5gsHtne7DA
# DATA d1Ip3tEd2WsUzNOPZFrzcw8fdm4M8pWMa/5O6ZMkHlEAH9J/4EPdNublh1v62HkWl9L0KfL1w603Fk6kqwBu4LMmRd0zOxR0qBr8
# DATA pNlKTiHcHaxec7DaHah+SQ5Un1Yv/NketGa/ZOZKW8QRDXJamHtJ0sXZYo/9hOaYLZMkEMgane1nfT77eTijyH9fsFb7soPkF63a
# DATA vvxc/lL99g2OyWd+WqMfHolAHUpby06qymE0Zh5HFIU0GUYQguGjtVLV+AS8cr8xkUV0A/Pny7OT4wXIIJOtmTV2njNCzxQe4KTX
# DATA g2NaH2gW3UMELlWNXzF/+Pw0IuIL1UQO5IaZdfJsxGqexWlW87wzqJxBtUSNLqtQTrDGCdac1Y5aaa9djpAN9+m6GZAlJdoVrIHR
# DATA T6bJ3iQc9y1R8Wemm3YBAEsal99QMjTW6HVKzWIxBhDIBQoWq7FfD+bDcMyZY435y5RvL0S1+AOW95a+kWojFFLQ812CcPGbsNX5
# DATA RSMvekr56KWjC5cPZtHid0bpbBBORb38UCXvAAkdUyfe86i/GwwuQ7Z4xppKU82dmbEG+FxruNj3BqI8DYnvrici9Hqco+HvYt/F
# DATA 9McH0SRlKSasVDHfXmRhmG1UDGMy4GdjapDRBatRN7JOdM6CpuIMwYMVBogY3BcsET3HmsymZRJk3jFJD2mtIG94aMwP6W0MjjID
# DATA QNqK6mY5KFOUx+TArj+qCR1m6lMyoMmJo3SFtFQHgEWtK2XpUkEViMWlvEcQ+I5GHoNXRh0qKC0/1VPUA8r7glHISlTvrCVNsfB0
# DATA qLWSeEY0mbXbEMnncmEmMapJMmB8sYwDonE0mUHIy9OZZnS8lHszkheYxe5Q6aZuhnp8caYflkHhJiBuArIwAclbmG4K4qYg+SnI
# DATA yonFs9bSVLwOZlr0wzHDhkPMMGxx7DRSuntaCnJOLJJRO1odUqGPIpnMWDqPU1sAEmPl4AD8pJngQuYlHqXFzqgpU99FpbAfLVF6
# DATA 3FRtk1M7vvMmL21m8W4fZrMj5i63Z/Gga7T4VGTY0bjoNlaHRy0AvUZvy2o/A6vwSVlYygLSP2bwbHOFVQT6zIrhnk0WZ2X3Cg3d
# DATA VlLyEHD1XrOFAFap+vyqbIxQL7fuMD2r/dSrCfewmeGHNXiMsdRs1H1sWybKkTt/O01Q1WGGt/jT6js7g3jY5ojiw+r7qGNOsCmL
# DATA 7rwvH7N7b0ra7sxhyrWtKavxtqmJEWWNoZkrXWwGlmavzkhnlnM46ZrpKW9+kImqysd8PsyBuXgntekOZGeBTGxnfHvNezI0yZiP
# DATA t8lUKEdW7zyMmdXUjRgmRK21Kl6CYZJOB4cKfomfYCUaKXZeqxFeVzyayhAYiRwmdkmm/UTpiYYCPdfisQwUHxmpWWq5PC3W7m0l
# DATA henBMlPWoTqodbUZWD9FBn5Ac+IB++7jSYemi1kWYo5KHQNQXHZHp2Y58JRQt/CJ2qJDPdk9XiVg25j3VsJsHyZtPEK9XyR1mori
# DATA SSqLZooCxmVxEdlltZJT5ldrbX6ZJicZ9hNIflK72ItMVsGbwPfk88gguCQjS94HNGYWPFbJi8kIO1T+JwURo+5cKHGyW0XcYZoz
# DATA T8MGY9yi7kVklel4TplRjbUZpXoxyaa34ccRcz4eWbWKX00V4oBimbIjJpwM1Oqp9s3AiYBtcCG0amWli6fZ+Bnev73DzF8YYQkQ
# DATA e/KFnAvgGPd53A4hqcvoCr7pmbbJ4BRt8l2A6NCnUbsrUqKLArkytc2+TM1NqHUqI62VtyhMD7G4p4lw9AjZ/CI9zPkptkgKjJc1
# DATA I3+WFcyvbF7D3k2oiGmMHESH7CbI6tiAfsksHOXdFYcfzW6pCbInLjPWkCHUw7PDSi+iqkVRsbagDowTOYmqo2StiAsKNMJJ3Fma
# DATA b/mBWPbW2QOxuSLZcOf9RO+C08rTbIKp3WlwiqiSVJRond+lkxhiL4oDImOJjaMp0Lw2Suy/C0jMO/rD0VceY71A//rz8X85+uro
# DATA z0ffLGLE/p+jr4++LR79CQCw418DQPbvwIUd/4qu/9vRd/T37+jv749+f/S9d/ylhI6gvwF07KujPx3/5ujb4y/p39/iTWCR0Zsp
# DATA jK8ohK80mOzPR185mthzQIEeycoP9vF0lEp9RoEeR8mY+Y0MWOehndqeGIjdBMrn7G3EQGO5pJUYLt+FPjoTVuc3UA8Si4Q8O4/X
# DATA UsXegrnE7PbRocOJ2T4U1RFcNU0sXyCXixGLR9Ya7n1dS/Uviyyx0RSHAE0fi68y0kWTi+SJhVNBFPTDlIZTWLBk6Sa9nsOJbVpq
# DATA F84UuxcOOlh1jGQB7DADVIdD3mnPSyADXifxephKeMyFY7k/s8oBku5wGPHkF2MJryPGv4iYvuF142i6BCN2YqVbbZ3k2tKzY4id
# DATA mALHEXOj+0WM7pondupB/aVYFLmqAf2Cx/ONF0NONZpf0WAuNdLOg2y71bNvOpeBErPTKo5htYOjn9BzWHzIJxQpMLHUhYVFojVJ
# DATA fwcM9sE4FaoSJ20apk/UXhVEIB7h5BiO8aks2QwlBoCRDNX74HUpWFM3IztJtZFhvaNtAsCnEmy0g02Ata2YDIQldsEMugvxdJk9
# DATA oKwBBh/BDsDqVfqEAjPxiOEc59pE9WuAXdrYQzabTmIps2TUiSaj1HHEHEfMccQumSO20Uiz4QmMDY3jKzPyz+Z7vAAT39HEHE3M
# DATA 0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTez60MQ6QWWRdLUp
# DATA TazXq0XN54gmZi87nxYj5gdVr9pqfFqslos+5U+jWvSD+qBYA1bL/9T3q8XA82sVzy9XvEal2PBwF+7wm8CA5bOu22u1Gr0FwhgA
# DATA X7Vyy6vQO2oNr9YqtuhCxWvWEWTgBcB4eT7CbuF11VY+2KDe7DZ7S8Bc1bIF5qq0AgPm8sv5+tCuNWrRkgCCmhVA1SJ7NRerRG0Z
# DATA GazSOO3zVr5Uqw2vSvlQCbxmkf7y/WGl5lMeecjcMmfx6oTYpUh31oKgHzSac6Qz88AC6ax+Bk4ZtwzDKeNGZnHKqB41GuEGnLKw
# DATA V81xynqVbqNTtzhlrXqvkXHKus1OrV3LOGWVZr1ab1w6p2wcTU+klGF80fdtgPmyHGVVdpOVmrw8hiFtZ5EEZkLWmLPcTLcW/MgL
# DATA 6E8lYKdjDs0lOSohqAhv5lRTqTKOtYqZ7s69vVJjXyC78eZsG/E8rUF46XQVcvFbM4TnbtMuMIfscsguh+xyyC6H7HLILofscsgu
# DATA h+xyyC6H7HLIrpcM2aUsDovD1Q0P0933wmm/1BskNLGB2ffhFg5jUep/DJPmprrG56NwUb7SNAuGKrUatj4/3Lo7pgneU7goo8Eh
# DATA 5cYNBH2DcqU3E7kwPh7Ws3Su1FkrXkUCKQtILX2YK1SHs6BBhiDl2E3Ih7RxQMWcwRK9P0fZcseOT3vs2B03flGPG58Fr3UNjiGz
# DATA +077u9ZTtkTAysR76VHlJXyt63J4+bk6w3cZwK38cesLJm3NVYazIrYsR2p2iFzldIYFgTyjCMgr1RXOrn71zps8wWddOa1Dx9UH
# DATA QqEjpTcnB2FN9TkI6Yl2coDTztHebAD5Pi07N4ScaNKDGn53NuEKGk6GWvpenYnnd+sI3CXbOibjl7fN6ihoShhlTw+LpG3W4pzC
# DATA T+Tx5hSxTLDUOuC0Qc+O2wJOVLYjvLhLNtls0jbCky/JUU8rDGdXObtqjVibXbmcrovTdTmtQbUGt3U5ei9/PUoO0P2L4kA73BON
# DATA NUhuqIHNv3o5sQuga/EKhNoBoq/ltOF5ok9XfzqC3kKkZFiMW8zbfrK3M0cCGvE6UAbaUUGYbkp/z+GQKNHUJUNPZhizvG25hD6b
# DATA ehbZkiPGEfZyZj+ukLMXPwSAPrZgyxhbXGmw3z4xvvr5rF/VFzIIV7O8LM52jLFdx47ymgizp4QpTXBXZzo2yKgT4qoeNVHV33O4
# DATA sLXx9NfEco6gpNaX0FqV00XUyLmqW5QkVKo7r8peUxVPtcZoa/lml6R3ifclBTT+KmbrTQnifBQoi9lktW9b+Ejp0yvES4hmb/QB
# DATA 78P1ZDdgbtCslRI9jUXFhYc79DjaBfXpjHohaJWns729iD3QAEbwyoTqIJIJMBaAKrGqNEZhDnQEQMVA07iEgca+cdXuIKBCpvyM
# DATA /fFUNNCDgUJwuGcYsVCggnGaykjejXssnTIV/SFWdvbUVt7IxEfk6CFNxNFYok6USRKxrDI8jYiMF46pzmGA25Tt9IIYu7kRzJm7
# DATA ztxdae4umDbO4nUW72oT9pooHN5j9T1oFvcwyMQjljFbznfSfNlMCnASDWNGdBRWqe69KUzBheGGhc32ZnEXOMNsYKTQqL12ZwAQ
# DATA 8vA2bwLnoQkLAofmPhrXDdNU+554qP8pcwIwnk0SGjrCqR5z2Q4fUgOfwYRSdkC4N4k0vnJxyFT6hxRSl4Zqkxy4qhYGTpYGhLgM
# DATA e44i1oTzwikqNEX4tk1t12TI6Clvj8I7YkANKNdXzAhE4i3Z5/1NisGp+bljzfDCRk4BhTyNJp0Y+x1zEFTJcC4YFu2zhAqVl6zk
# DATA vQXOFnej7E1jaFcfNhffxQATECvhrns3mnI/y8mAaRNO5/xtOLhmIuvx4QawT9al8a6WozT9vU7kB5i1afaO6vuhMlkQzT0NJsIj
# DATA WH+kgh6kBaZjpIbaqY0uMZPeR2DoKQ9hgqmNljyyTHhIasPSjrpxJ5QSVPhMZOVCTbcwZ9FTGvMGh+tS+T4fKTbmF+NLdDrv8k5P
# DATA dUhkNinAk8wK40Nd/Dx9VKScGPATZb6OoMSnxD8tRhonKa9UWfIeRdETpoTALcs8D+Ql36qqhVaszPFl2H8q3BCoLcJBrB3FYcqT
# DATA 2nBvlKRxukDmYEPsJJ3vxwl1TJyfWRfErebUpGj2aesx6EI40ZabWzUGuLfZiX0JZOj3UH31PhhqriGqrui/62nKJVCi7+Wc5Wiz
# DATA VN5Cl70EUvS78ZRnZRPqtiAEKVBIxazhnlMEJi8BFv1gIO9EB8mpzRoXT7O6lwCKvksdkG7x6KW6Rl+XixTeokn3gtnJL/r8zeLi
# DATA 0FPT1Mbi/DMgOEffHX11/Ouj747/8ehr7/gLIGro69d0+Zvj3y6Scf6FUTf/ylCb/N1Hf2RKjkc//erod0dfH/+DCuW/gotD174/
# DATA /ls8Qa/6Lf3yZ3rhH73jv8uRdiyYjkPjPAdkYQazGe1aYWTB8wukR0G2oQoXuMfd1gGg3AfKotqLWDH4CRzOghOealYiQ0Z5EAVD
# DATA cG+wnoDzbhT2+C0Of5ObY3J7v2r6jVUYl4e+kaRl3SLXnR7Pw+ZvxchhbuSp3qR/OO0PLxJ3w5tsadrTR43v8owAyD3eionbHfbm
# DATA xBK7cN4NJrlJG3NMrmfaY42dImo6zP3LIJwM1dJUNvmMU3FFL+yhFv10tm1lLkGlRb0YpnVkusDBvYC/WV//VhsfWTt6Vtib9TF3
# DATA xBs3aJ9i0NZgm9ON1S+HL/hqxumLHKY3GqU3H6Qvf4yW6mcSbQbkq2sLl0GqMekRQnI6nxC9/yLbxMD2RD8ZahiMVSYy06UBDYNd
# DATA 2OWEMgXdEClSxVjuJLOJsCmy8VUnXI6y00uQVxz8ZtwaNcXPjcGhca7r0duM2ynd2J0NIr0lkpew4FX00nHUiaO0YOKfsYuVo3UQ
# DATA i+s1os427EXTw5wrUKWDcbqMiWYUcEcSlU+QA9Q4QI0D1Fw8oObkgWOjOccm9uvV2N9nMb/Pa307GI2D0TgYjYPROBiNg9E4GI2D
# DATA 0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPROBiNg9E4GI2D0TgYjYPRXB8YTbUWVbtnhdH4veC5gtGY5ebTkmiq
# DATA laZXrZX7jJ+p1Dy/Vn27GlTy2dHpNcvBIv+kRgmo1ho/8yvVef5JLejUmsv4J1xK+WCqrZZXqVX+k9+qeJVKmf40vJb/qR80vabn
# DATA NyqeH/j0rqpXaVU/rfj1ol+lMgQxp1b063RLkb7RTTW6yacHav+p0qJHK16VQqg2P/XhRa55NbqnWs+lqxY1W/XyIiBGIlQkE77o
# DATA +82hX6N8wYvqZeB55tLaaXVbYWdZWhV6hkoxJvNDsWtq5SBj19RaZasC1+TL4ZLa3O1E9U7vDOwYrsiGHcNtwmLH1CqNMKieyI5p
# DATA 97q9eo4dQ/FpdtoWO6Zab3FAwo6hTqIVRhY7Jgja1dqls2MG1ApOhMfAafR5dquhvFgcF5W6RcceO/cq9G/zR7a53WDzIQvyZCSN
# DATA zZvhzXayt3hZLIzrqrRk/ZQsLA9LlV5d/uRC85RFY4AyPIqa3j9HrpEinksxhQnLyAvkj3GNSrKbMK5sf45vrfGoIBqUYT79Uf9q
# DATA C5OtVx4QV9JqNijLfNbl59hLM2JlQA5q46A2DmrjoDYOauOgNg5q46A2DmrjoDYOauOgNi8Z1EYbhFraZ2vntXWjGcNvdK/Ppy7U
# DATA YwX0gUu7Vk+lzKpUu3di3Xvtskm8cxvt/MOte5maFw6rWHIuI8phpemC6WueWWNOPrhzw+7csHXyxZ0edqeHTzo9vFJr8lJOFb+O
# DATA mguluSxwc7L4mepPXIBeOrTm8OaDKHrCJxylzZ5Ray4bWy5ObS6KBkqVuy2rJJQhWn1QObovQXZOnzdW4LYxlWp3Au05j+ZI0eDw
# DATA EjTn3hnhUPNUethUKWXDXu5lAtWXID73mF1fKo1kgqjenOoEjR1FqF93L0F37qEcJYYPkEw5lWQDF7iUcmXtufdx1jo0AnRoeTLC
# DATA wWQh8xJ7oWaT6ILV55QHxkjHZ5qMOWWA7HCrTog5NUsZhi5gmutBLIn6TBReJOAhoTp3WJ97o1KmrtmdHOqMzlAN4eAA3MJhxBLy
# DATA uAULVWRoDAYl7924Z5pDAbiHwWJbVCqqI0Rl4vXpx0mEBavBoTzJ3ctBmEp0NFFIqdVyHRSVdzQ2eHNFu5omFVhi31cBUOugaEp9
# DATA 6cM3OFEn4qGTSY/2aEhZJRmgc0Uf96ducoST77zNgMYTlgKgkXpe4mdupHoY4TigOsUtk1a5Q8adk2Xjn/OTxw456ez3zH53FvsL
# DATA Z7GfFin5DHWAeDHfLESv50i+GbP8uYKjQPR85PFe3jUQySuWD7r2chqXwYfMRI4uGg5py0GdlQxpbVLQ06aHOFZlqoNM/Fg4RQlP
# DATA VeYKErsapBTV7kYQG1+fyMOgAWALnYY23vUGs2E8SmY0RTQ20YgqeQIRm3E0GEDaHWNoXymuk/01Knk/aYvcPhkm2HQNLaU+maQK
# DATA c8A8G/12OxpvwUDjuzgxOhbvwy6iICh2VHmp1lhmF5t8fH4k4m0Ihym01MOUJdSlhWiN5yEkrCfr3s9uaC/37rekBaVkXqa8FF3y
# DATA 3kvSqbb/RFyI2T861reRQdK+wF6C8g3117ANIGxP3QhVdZYNmY/Jiy4SY/UMzlZztpo9Mjhn68vrbF3NnHyWEo7v8WKlrs9KgI2P
# DATA XltQSkjrMRxhH9pt0n4y502B3QgMmGQnmnYclrwHmRggTuGISptB+3AZstMgtPQD2afJvoNe3PFSmu53jGelzVvJMs1A0VzcUAOS
# DATA UyyOj6zxy1ofYjIKJxPNE+LDJXgPvD5LjER1xnGRdqnWuVFJ+ZPykylPlv4xAyKaK5zjwI5EHI48rdxPyWBgpWApAdIsnnM1kc+v
# DATA ypYA9XLrDtNR2k+9mnCHmbnvsPqMEXMw0EujMfyhibLm5m8nu4FbVXKw+p49NnsYmcWfVt/ZZjuNNbInYqXoO29KqrJ8kPFYewtl
# DATA Bdr282FoWOMqXGszWp7PcNI1Tnhe8Bd3vMpBKwfmQFK8M9i0fllK5yo0mXFO3DUJmI+x5OWYDbZ7EHGMJxAyRb3PzFbYa0WlyVkQ
# DATA idEiZmZag5SGsWHSjdiPP4U9C8NPW3CCUrKdiXBAGqnOiIWGtJE99X5BA27J9q9u6Ev1zDY5tjTySTFZoyXMAHjFcjc3InrGcrrO
# DATA 27KnKp6s8p2yhB6tLiFdjaWQHo3ZB5svIWrG3JGIxx3YF2hl9sn+ETdo6EldV1a/xQ40ayB4XlZBRGo1gfoophwoXexgVFbK+cvG
# DATA TsH1L5gHmxbMg3AyYFHZcDDUBfMo6TGMdUSjGmumHmCSRyPoXn5uVvLu7icxZsaU98atX7Bd31wqY+pfMDnrqlkipofnLg874ldW
# DATA Hlnfe8ry+KvV5aF7cSmPvyKDZaEjm3U6swGryWIRUJ0kVI1DT1YVS496KV5JwHlsGjJK3tvUug4LVIRkhiTxQFSOh9yLJcOhyD+T
# DATA cTEUlhj9FCMHzXrx+QsqS9H1L6aHmxbTw1m7Pd+fvc4i1qo3i0afJIdZD6bFuEreBzFNd7sz6uj3ZCnKyCfrVaHMwgNTm/KqE86E
# DATA jnfusrCjff07sTc37cRejydd3jEwggOIGsfIajx9Ubzuz4Zxt4iFQpYYV+XBo07Khj2khaawzD8INZc6W+e3eXsoYdPbUUhkPKlt
# DATA E9BChnvo3OW0mKAzlVbe/pNtjLb9Z65I3t95P9EbDrUGt5j8YnHz0j9DLUOasSA7dCmrhdPLYaI91x6vjIWW9pMoh0L7v47+9fjL
# DATA o98d/wasMmDM6POvjr4++rej7+jv3zEe7Y8ew86+OfrT8W8WwWj/zBi1r47+RM/+3qO/OMCjbwoU4tEf6Bujz+h/3x99bV5ik9To
# DATA pj8ffY1PiqP2b6Ci4f3y3u+P/v34Hx0V7TmAcpttDrzlNZkeaOyqIXNDvFjIqwWeGfE2qwgmnmYBABoKdwLLyFAHIHAGdKBj0A0U
# DATA 0ZXq8WTKe8bwXE+WsIxTAJ6OteQ0KMujKYid7/Bptq+Pu4irpqfNF8jlIdRotAgHyV6G+OIdhvzyeQ73zV6cddNvxlML33FxDDWY
# DATA 0urcBmpoIiM4Z4PDp51cWhfOT3tPMOBem4wL7OiieX+fxh0zvSxoIytNcBgKGQlDFslEd6f2tGJ+o0jjT6GSEmWdE+t8FcimkuXI
# DATA ScSeRSbM6mMCQyoiwWtgsJousNXW18vVRsxcK3tWgLX10XeANTf+X/D4ryFsZxj2X4rlvasZ8i98xN9owD/FeH/5w71UxHzSzSh/
# DATA vZrPZXDb8gnnQZIzxEDHTKrbhwipIGcYJzN5lcR1KkCndBhi4cssvXnSL7WjFC6taIKlSU40DdTZsQUVvW7cM2w3Svahp0gmGzLb
# DATA Jspc4201OLJCBgX7JaLOE4xNCk3GdUy4V3xqmHcCCW0uTnkPVToVGhcvzUbpVEwF5EtmOdxWFDPQs6YzCmEYjmY9fJ7YRoLyvMJP
# DATA wDbN5LCYjByyzSHbHLLtEpFtG4wuG010NjGJr9CuP4tZf16r3oHbHLjNgdscuM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdsc
# DATA uM2B2xy4zYHbHLjNgdscuM2B2xy4zYHbHLjNgdscuO3agNv8oNqpls8Kbgt69aj3HIHb8mvOp6W3ka3qVWvNT+tBsVr3mtWiX60M
# DATA 6J9KxWsGnl+mX6qeX6FP9WKlOqi3vKDutcpepfFptUZXvWrg1Spv+37r02KzWG14Fb8YzGVp1OpVuu056JnfqNWrtWXQs9ZiyVXK
# DATA Xq0c9INGZb9af5u+5l9gwspT2CqUgko98Bp+0W8Oi7WGV2t6jXLRb9CXmlere/Umfdk4Yn51IWaBD0hc49NilQq1iLyov0cBILaD
# DATA Kl3I0eJ4J2f+ZVGvUV+BuVMVuBNP+ITdU6n0lQz95jcYJMeqBvV8CzDBUgAwbDx5uoys9eThZjNf7Xs9/q77X5ZDZfHXapPqDYVx
# DATA SmwcNyONjZMWaWHjoqBZC4I8No5uqlXqOWzcHEhOsHGtbivDxtU69SBoZNi4bqfT7mXYuFa32ipHl46NQ/s7GRtX1UaBmAT6mRX8
# DATA OCRzzr8Y/Mir0Z8q/akHP7KDmOPFvTOkqcS0gK3AiK/3Pit20Fc75vY0KSiXb88788TdU2juHxR4lWzFipiKBuBV4882XSoo1ay8
# DATA 8KqTfDCe3k+RM0jMfAm7qrWLT3s580w7lUkV+uMH2uRnX1E8JQurkwPZaR829cuVBfxceTVfzuR+wc6BNabICQlkK8Fx5BxHznHk
# DATA HEfOceQcR85x5BxHznHkHEfOceQcR+4l48gpiyPfAcQjCn8X9t6HW9LmKOE35DsUYTgb2MT8cOtxOIEKLT/iyc1oXjf4AlWLN7GZ
# DATA btvfuUG50RmWPqT/RnetU+L3f5o/hscPvxdO+yWeoW9zOD/2SwFCyI73LTk0ninfQorLdPsaNZcdW3GHqN0h6k0OUdtHm9xZaneW
# DATA eo1e8rM9Yy1Hgwv6rO+Sk9YPzblAqSOFvLKaOdQrB1aVIAufJYYdfaB0mOUkb8Qq+9nhyXF4iMm0HJ6E1srIOjm5sQbym6J63BZG
# DATA VBcEKrw6NB06OgKne7yJ7nEnTGehkk3Dp9V3okulrMWtH8jH1fdSB9tNEs7on8jH50EBOcuLU4og3lstgqhzVUQQySibHHahQxSO
# DATA 9sM0U0DEyUlqXlAQ7yTsNpmNxzj3jI0GOIzmTUQWMgWeQw6zsxeMmlpU8qhVxzg6PKejw+Nhd3JY8KIwPeSGcn7dw7k0XJlEpVX/
# DATA Lk4x1NRkpVMN22EygxmZlU1nlvap5kYskosz6HKEOhS5ajZzMiMCViXsEsEwoKD64N6hi8iUqZWeAx8Pn6F+wF/a1syTc6lTZwl4
# DATA Dgrmg40L5iFV9SLcKofQALeUQ/lgc4FKZBxx6+FmoxsIg2RQcNQfoeFo3VCcI4RiFRTDozHbhshwS01DBAewtiXjWzzoJzOWHj2/
# DATA vmsuKVdWSmfu3N7dtHN7L8bOGWh4zCaWMjJNUGjOh12B02Ssm04vngwhTjobe6pgkglLsPGvol5yQImaJG3p7iYRvrJu2GzUJ6MK
# DATA 6ga2jMd5iiQX8ysrEWuQPGWRPF5dJGa4lTJ5PAnjgeilhGTWmEKh71MYJ7DfEsnhLk17YOShahoa5iRUzUFpVgMmrJVmMiWJTOxN
# DATA RFgGh6L2du6CyUf/+reVR5u2lQ9kTkoT1HhMVdgUDGo3LGeaussWIRjWPIzzdBSqHuOUx3tM88GjxcZchcxKRTNciYRPWdQapQvP
# DATA 6bmLYi7GL6/W8YsgJ6Ifd94t593axLtlVzHn3XLerY29WCudYJfj3WLhLQPAC729JBFRPO3burb6tet8XzjS4NkesAWnltBNsWFE
# DATA 7UPW13LeJrU8w2imEfbf80RVLZRud4Y7yu2lG6ZMSlGKEqp53nRl2RXj+qnw7toJem70YsOYDaQKb6sehrzlVW/kjca89brkr3aQ
# DATA 8QoSanmiynVsVMvyfjJ1o4mZfnDBNeUrQi/snu4tz/c6w9V+LL8UsAOBAoujCd1dCnL3L/iylIVlHIWy6YaCuK/lC+d6WctMQvlR
# DATA FPhwkU6V7L6yTZfskjTxWMyzMY2HU9mQflOCOKcBJEYKBiOrvdlqlo8n4n4VYiz6gQWV6AHrNY60l7YgMwa24dgrEu6Fsey6wpZ4
# DATA wUjR7KHkGchdVk9LHhdagQc/C8jC4pVZkNCrTLV1jNfBmhrHI8FYIUyyiI0EIRYUWUENh8Yg6dg+lOYpwnwhFCjtVcR0tgd+Le8U
# DATA yNYw1bR1pCUoWa8yk52csYV66JntAnpP3JhtGI2XRVa/8IZnNtQ409OZnpuYns7WfHFtzZXW4TVUq+YTHeZ0waIZNrDM0LdgdnKs
# DATA QCGfRLJMmGorNHuIZZe4871+6tbXX/KV/5ZzOndepR50vmHpY4EI1xzhasoJP+vMolwIB/xtXoR7/rieNNNOgsmCvOtw1BHz2+hf
# DATA 3fnJwmk/3sFHhbggbm49xV84LRsIi2fHVrQ9NgcHPwgPefoCPWdjmN3jJTuZHI3MoiD8iXsU0vhQlhdl7gQa4Tjc57lLyXvIy1lT
# DATA bUGpe5R9hloJl7E449jgmV/rCrEeTlaapnVsVAnmK9P9p+MBQk3jp9i6LsuQUr2vHO5x5cZThimjCrUfDfZm1F3YsLJ/Of7y+NeM
# DATA JQNB7Bv+/Cegyxgb9nsQxfDL8ZeLlLL/3fz4q6Nvj74Biuzf+cLvj788+hMuFbyjPxx9xSiyX+M7buDXHf89/QGI7Hf0OoDMvqGf
# DATA v2KU2bcUwHf47fgLCuZbwMqOv/AojK/owt/jItBojl32XFiHSBtPveAPYblyXXtvgUgaTp5glS8cRQW4PWhWOuG54ziU6Q8GGZqh
# DATA 4qg0ryFBL8ObjTgw1iafxQNmo1KLDnk3J00sw6lAUiNs1afObC21TGDSkQyUDlpm24pWh3HV6LK5Urk8clk3lnOYqbnzDXWFK+oC
# DATA vQzjnrmTKp3UxMkFw8t4nh+nvAEBzYF3humoOoLZZqV24RQz3dn0Yn4uHIhTKe30o+5MtokMhB0PyQ8GOXMv5rHaq+cHxWE8gq0d
# DATA DqhyYx/Jbe3pZXSGWGGTiAIWkEI8QhcsZqCyjKRNDgy+edOqudrEyTe1Z4UvWxt5Ry9zFsCFWQCaW3b6gf+lcBBd5aB/0WP+RkP+
# DATA KUf8Sx/wpT7mEm/Ty65F87kMblkuxV4kc/RUPFJM4faSXn7fHmfDtE+x3ON1EzS6GPs0jWXEiKNhOOaEy2vRR8m5AaqdoC5hqUUj
# DATA k2S/Jo+4Uu89I86Wbogt45xTlcKj7JjhdTLgAwgi7rIDbRhQEaSIpdfFgR+8/MkoOZDTEV21uRTYqHHERd1PZhOwv5hBFbfjAbIK
# DATA 1h2DVmg8YtwUjAXRQGA8lzlDoEBOo2Q5fMpxzBzHzHHMLpFjtuFIs9GUZwP7+OpM/LNY+Oc08B3IzIHMHMjMgcwcyMyBzBzIzIHM
# DATA HMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcwcyMyBzBzIzIHMHMjMgcyuDcis0qwFjcpZQWa9XtgrP0cgs9yK82k5
# DATA ZnXKk3KtX68396ut2tv1eQRZJap3eos5WfYpK2v9oNngz1VAxtTnGmUsf242PZ9yuForD/1muUj/qs++/jwH9aKc7/Yqy6BeleZC
# DATA FCoBRaFc+dRvlD3fB4LNq/jlqQ+3cfMkfFgjCBudpW8K6gs4NL8RgEvmVSvFVs3z6zVA0PyAMs6vMvmt1jrhdZ1qvb2cVmZB1IqY
# DATA DoQQ6Jca7bWWgMwoLhnIjCJlQGaCY8taQK3aa1Q2zt/6kldVyo3sVVXfv8RXVYXIJq+q1BuX+KqgYqeqWb7EV9UZRadTVb3gDDwV
# DATA VI67NA2Vk97RgsrVKvVqs5uHys0j5JZC5SI/anSDDCoXdOtRs2qgcp16J+pYULkqvbdZv3SonOwuLMoygx7mqjyD8PTqlLFdmmL+
# DATA 2c/MQ+Heiqgzj8PCIv2ttoz+Bv9nY/+gUBf/pwp5GG4GeSs11rk19fQsC3R+gcQ273X5LHg2VcnkwmFxixWur79sN6kD6+adXqez
# DATA wzx212KpajUYzsqqNfbcQpzz06JLtA4dY84x5hxjzjHmHGPOMeYcY84x5hxjzjHmHGPOMeZeMsYc6kI8pRn+JIQWO1Ww2wY7t3vn
# DATA MzMnGae7XE+kl+Lzy7j6kdXypeHv3jHNPu5t/4AfVQ135zPFpdPKRRBDlTNfjDgac1ctxuXtz+XV3ZmsPe/aAf1YcHe4lCHwmEsn
# DATA Szr2vUV/58d+cMMPEB0d2h0JoD2j+SIK1cSM5WZZgXYURd0UvDv9DCB5IkOQGu2lXnQgHchYTuWJ2Bdd4hOMueQgo3GKcVeb9RO8
# DATA WLJKFp+2eUK3U5LFh+3tsLBfiKkQwhvK0N7f+fF2TE2j/Fq9fMvfKZSx6YtbPdafdoe7d7aHd3b9Wq382odb71OV5COWHCoySBk+
# DATA nE+9QUJz1uHNennnR5XaDs3AuqxntV0pfLhVxt38mH5m+CO6cfGm21nNkSxHDdhOOdaq6sB5tMvx20bqGTX4H1/8EzI2vY0rN3aX
# DATA FeZ2/Gq+EF/zg1tlnZsc6u3Pd0qfJPGInmVwoURafbyx5JW9eBSnfSWK6ge6MHFaVhwuAkD86QgqE4IDwPMMPdyeqzBFXSt27GpB
# DATA jYfrkcmWHYrkbS5wKominlXQ86+tMxm55aHxZOF8hnGQjCF16FgrZ2hxCx2yZivqSmfmXRS4Pg9dmj5FP2PFUcJ+pMPUD9GAi7AM
# DATA plEfRHNKEU4pYr1ShHVM0elFOL2IU+tFrNQpvRQdiQezadYAeNeW1vSUkd2ISlxHGaOr0LEXY0Vk3Cdixcwp1+NSpluv7zedl7lg
# DATA hN7LrVtqwVwJ16/Qo1cDLivST3GynHlIRth7W428Jynpm2BMlLIrmZJ+rbxMSr9qS+k3KmVbS98PVkvpWwYNos8Rp4kJzaq4WuXl
# DATA 9HM3W/lmB7Ggls8xu1Mta/tjta5+jeNZC06+s85h1peEuaC9rw8wUrr5IOIdZRQLMwgth26VX1TOZEwoTBo4Tfly046P+UzIldN7
# DATA 2XjGQ6FMQO5Yl+cK5GJe+xDjJrd4+63Z1ct5qRx89GignVA3kXtz/qcM75mVy0o6gvRkChPw/CIR3oV/T6RulLGiLXlbOcNozHRp
# DATA QmfZ/blOns0gCH/kblECvFSFWXsGkjOsp8FwAxZz0AyCVRo0edEZmwq2yP9azgmTDMzNHzAS6hUK9m3pIciGgJ3IN3j+xS3yFoab
# DATA l7h5yQnzkpz96aYmbmpy8ozjmUrcYYxHBdeRQOYMMpW7N81ERIAHrPlk2hqVXpiyyBUEp1hzzIhQFUQ5bRiK49IIoWmxhvnJxRx6
# DATA AdtsbOy38GhtA0z4mh+I8FwkhFm4StG+KTFUoVMzpWFGF2VP+ukM0dzj32bpIY25I2Z6UQKlsygoCJFMj/RAy0B67i7SJzrQcT+Z
# DATA JnuTcMxD9TiCIa3kfeMJS49JEvPD3jRkrPJ7yUSUddVYNw83FUSyZflJasUcsXBo3JGhbztQGGRsE1Qdm/jusTp1ABQ59OHuCj9N
# DATA sBL90MaLwkMOwgBLrcG3ty72cZeturWRnzceJQUGKSAQ4dQQhKHiPzWg5w4Lwin8hdYkzpT1hGWb195TxdJGly18AqvXDqX+rknT
# DATA XeywHyUgt84nS8yEPDd2QVXRVGQyCx/Ava/ejHwls60Pgq9CNkgW8A8A9iLyWEvusGwbjJoCKtFIkgLmHby3ySxV+aECjikf7u4n
# DATA cZclqVmlDQAFyVIaoBImxg4htTbmk268O2X5lJ5j/ddCE1EOcJmU6ThjQT0nXJ30ZBYGHbrhMOlK40bh8WVTVp4+PJf0evCp67LT
# DATA GtZShgVvPGuThWI9x/pz3AjDLiwgb8J1WCorjV0ML+ZXeiCx06BDlnZKbXJdEh8BDa7gXlMMIlYSQSiTF1LPEEPbi7o7SuuYnu/N
# DATA BoNDxVtRMWU3TsoVVdI9zJEKWVlQ+oSDfqLUEamDxE5QKuJJH+1QCgx9/DyiVgzTF8+edrQwZ0tvrAbtTOcX2nQ+LSvsGatD23v+
# DATA 18PCHmMk0LBLNqqkvq+nhV0fNennQlL1JIJEtu9fs7wuEiqWV8i+aKbYvOL4UqSYcr+xmjcKlXehkREkNSIVsyYZ2O7QaKw7sTvv
# DATA s3aJcMVoqsL6xDJpovfR77jnzTiznNF7QDJ7BLtcaGRUb7J7ZWYCm1Z2pyew8GJIkR2qm24mg1XNU+xl2Lmovjy1CJc5GNdiQuCK
# DATA NSTnBf1xWGAsQzyeoEankWlmouAcmumqbLMhw36Iu8jOzXlbyeaGaLGthc6WNk8hJadmLEquDdyFdbYFW+9Fs/IyrNlB1Fbi1zbV
# DATA 7H87+vroX4vHf3v0PVPGvjn67uj3TBejT8d/c/zF0Vc2Yez4S1xZBJz937h89Dt6+GtGlH3t0Zev6OI3dPk7kMmOfufxPX9gxtk/
# DATA yH3Hv1Ugs69AUqMXfEn//laBzDg+XyFOx38HBhrzzn5/9D39QPf/0bHNnhdbVho5Gp4WX+clK0PexDoQzeFEXZwnbwkFN0WrRxyp
# DATA lf8UKovMkBfvUbLPXp5wknmVLBIimsdalNnb89FwODPbps06iqummS0pmMsjmolPJV14ubo+f7vsIDB3P4xSGoE6MmBzIV0w2kzc
# DATA S6LnD9eKLPwxtcCBzTYqvAvnmt31LL3zbGZgagAvGkNIZzZgCkf7EH/jNIVyz4F6IhEUO+feg5/S/aJpXtCcCr3fxUBM2P7ZB7zY
# DATA o4uDBZ7ZhjVztY2z2OyeFd1sw6Q4zpmzBs5qDWis2dmMgJfCqXWFBsBljP8bDf+nG/2vcPCX+rmQExbq7Jm0oMsgmy0kkulmlFXp
# DATA YrTAOJNlZY+qJ2rqLQE9Fby3Hz9+8KigDpaqlWEuGd4zOiH7gVd2OBkYoeGUyGhKE1WW2vOg81SPuZvizUxV8CivoQyWNwCQsrgD
# DATA zFlmBOQBZ+NJ1IVvJG8U2MZAgZspOgsPBsaoo8wDtgrAoRLzUJBTHP+UXpPRzdipkh6mfJRS3dN2fDPHN3N8s0vlm2021mw08TmV
# DATA gXy1Fv9ZDP4Ls/cd9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxh
# DATA zxz2zGHPrg/2rFVr1etnxZ5Ve41e+znCni2sP2+EPuPMVZnHlDChbdUqucNifr2Sz/WqsJwk25u5jOs2oyDqzeGbqs0gEFTXPL6p
# DATA JllsxUPeLfEQ9lUWj+r8obVKFo3aPLZuGS+sbvHC/FbTMKhyhLS/rHWbfqO6WHOaNao6zb7UOSt5Yb3d6oRL+WnrklcRUtolJa9i
# DATA 0bw2Th49dGHJqwrj65KSV1VPnyp59NC5kletVK5FI6lWm5fXSKp1/xyNpNosn7uR2Mm78EaSS96pGwmSd95GYifvwhtJLnmnbiRI
# DATA 3nkbSeA3r0UjCaq1y2skFItzNJKgUT93I7GTd+GNJJe8UzcSJO+8jcRO3oU3klzyTt1IkLyzNRIb2FpuerUg2K/V+9VWbb9Yqw+L
# DATA fqvu1er71ZMAqqsbwVlomGzpGhomG80WDbParleawVlomOUo7PkWDbNaj5o1Q8NsdzrdbseiYfqB/Hy5NEy1mVdmd5azRy27GT4m
# DATA T9jJRLedai1eY1+ybSIXKuavi/fMb1VYXDJr8pJZqYmtMrJolgtVLZivDbnOq2f5x/QscPlmw+xumk3uTcJhbo3upOSqZ5Yszy/e
# DATA oFfqF/J88e7Mi7hqh6S8yJciElfAQiBYalhEfapql18uaLVa8MCcDt7JHqMlqWK34YLveXG70Erup6N1Olqno3U6WqejdTpap6N1
# DATA Olqno3U6WqejdTpap6N1XgCtcxHNuRe3FUARq3MwPRUcUzOo6MpNv1xrBo367dycRT3Gh4fxmEYckmE+G+PKDR9PVmq3FRvzvjrG
# DATA Dv2A0bQ/ODScK0YkUkyoXr2J/f3bFcYivhW/LkjFd3HOXE4pjwez1INgs6dexM+qKK16/q5XCX5k3pYJ7ci8lPJgP2JU5zbF4cdY
# DATA 499ZFpLNMrTOmTpBGCcIkxOEWTx07NRhnDrM2dVhViopX6ZqjO6sIQch7QXFxUoO2GjDO28sCZnro2N2FUBDGSoZ9CEDGatw8NUT
# DATA QIL6yVw3n+aQbXAjLAUJ+hZHkG8q6zsNTnA1TdAM52AJqs8ImwVLxhgUdRK87b+OXz8JiGgFZ5JiXzOpCU5OS+UUyRBrAz0AvKJi
# DATA Emy/d3J89XMmsuaCFdPNMn3DmGo7iNsphBIhOZLZLdR1jePopOqSBZKBJ7NLJuqNk2JeXxPrlZA/0wXoKROPh6qQn3vo3zLSn7EQ
# DATA I9P7oWeiOiYsD24eXSOvA9uAizQc8hyAl2dYEEbNNTs0qWK1aIaaYG8kTW8K3kGfKh8Zh5O9yApN5W6vR31tezaBbwPP0eRqEkGh
# DATA KZ5qgR/lr5aZR8qy3KzERFXqUAxk1sG061nJu5cM2S1GXV9BifWMukb/KRNdUpO5rjwRTpQuUmbLZJDZIcVrNmHfqhIf2oAa+KIp
# DATA xTjmiZsIrJgIOJv/pbD5T0s6uS5KkfZOifXIk7diHjFFLZHXoyESN2LVHmpbw2gt++TZyUs+X+pqJ6lLz+3xuAzwyaKA5kXDT5bp
# DATA kC4FoOTKTm+JkYq8DPD3Jux5bSIsvYNVPdfe8bqY1sbQOKXctyL/Ma4yZsFBgERE4zOcSpkrc3MTHOajbNqt8YpvP37v3YJ379Gj
# DATA ghqHpb3wsKC03AGxlHmRCC2OoRIaaiVVVmqkUjCyn3GazRs02I4beDzFsL2GqPhIOgPZ8LYeFnnXioSqxDpFd6EEOlLyqBw7ThAl
# DATA rBuB5heNOlAEHUUUP6XHWqDaS9W1r5fZRJ41r8q6Fs2Z70BOiLoWnBVrWkdbwRTZ4FYHDCPxZwiMFGa/aN+zAT05VJKYKpYl74Hm
# DATA 1CDmvDqmO7LQ64XxYDZZR7N8KMFg4WoVz/IlssDt/trZ4M4GX2qDq0riPPHOE5+z7lYa79dHv53rNEbqDOcceuIpNB548dXEKTbu
# DATA JTxI5sXHtQt9nn42GwMnWPJ+hj3ihwbRQnd0Zx2IyAwxFhtpY+NvZ6Ix2zsbC7lnugXSPPH1zqva8HuEY97csKFfkSoAtsw4VF/w
# DATA 6k1jJU6l955O8FGEufGqjjjryd6YJDQGU8PuL73hpzKm90BtXnHLBzDZkErR4maxadx6E++8qd8vg9F8NJShqgw4Y/Hwm7p33lCb
# DATA E7kGFzwMKz3q+xMqM8Z+UlWbdvlONUYUPBmMC1pqG5w7YIrTvoTbVdFaEY/3whHVqa5tC5rI3M0k8Od+lyjYppuxv6hEJxHEu3nx
# DATA QFteJ0fkZ/FkOoOiOkuJW3FQBcxmHtdWlpTnPmWSDExkfjJmRRVzA1XyaMoq6WMePCmDBgNd1VMrPjdVQd1UlW4Fl3499vuRtvOy
# DATA vBeTL+wOadDXs5yM7aOVxBWpPe0ns0GX26WYsyNYfth4jqmVqKtLAZc8ti/JAh4kh0MOguxz8KxDiMNbMvRg0X+StHngVBLzsxGz
# DATA EFVI64Dgo+RA6ZVr0zmc9nX0P5iwnD3Ve4/FTcTZzest2m/MTmeyximYUHub0UtRZ8f34AdmpGY2LpBQgCzq23liBFL9CA52Gs6j
# DATA kb63q1iP2drgusS8J65olZ5QxPPhVzfufeVZR8T0ekbGVehHg7Hqz2TB0+qLWAafBsokB1UYR+ETlLD0mKh7WLPsRkO8wJ5hKbAC
# DATA hSLzQcbCoxXYUzNlx9jgc7P+ifoZDzdkiL9Ytv3nn3/0+YejrVf+4kX/j7I+GnyMDiMezQBVHR9e+Duwdlmv1f5CrRvP/euXg6Dy
# DATA F+Xsv78o+36jXP8Lr3wVGTBDm6PX/8XL+d8Pf/jDhzMhRHSoA4m7PM6gUmylvBe5yNiPrIJ49959h3oNXuak9p0MuryETw+UKKxX
# DATA RCqFbNs9Pmyjv39C9qH+nKSv8OiFTn8Qtz11+QF91bdMzIPprK38M/oKjmRhONDfZ2S6vPLKBw/vPnhw/yE2UG9tbb3CZ2xeURss
# DATA e7Kvmp1N2zSZ7Ea3eunWDu9mxMmQLTD4blKveBNU35udQUwzmK3br8hW615aQj7AzffocNTZxkMFb4vm680tawfqFjuFigi9mOXW
# DATA 1s6O9i+VoqfxdNvfuf3K/L7PfNT4HNnH6iF6A/WOByN+cxZQ1EFuFbyfq8gsf/dHhVc8z/tsKqdIbvm83aEwDJ++Puth76NfrzZr
# DATA hSdkZT6K90bh4NbWo3fe+ut33n13q5BOu3Fy6+dbdJ2Gh63C1jge4x/1/aPPd1T2qI2p0WRCQ88vf6k3qqYcoH2BF8tl4+vqLJE9
# DATA xLu501r6+S7GgmmijlWo/NfR4Adf44I65JfgYBRe/wM5PFSK00dhL3qH7KI9HFLA7SXk1z2sZO/gzrlr3qteednlO3zaZmka9BUV
# DATA 1wMYMtsqvvNvpPuzU1vzQXmfv4JK/MorNIWGm/Jjphttx6N0TKPwx1LoPPnfuYUiRhbwCjouwQbgDyW2JlJMoba3ils7+GEQjbbl
# DATA QUpI4FdwDU9OohL2E/A24u3J1s/vFv+XsPiLcrH1cenmrf+p+NGNrfwL8d8kxFTuZ0jYfRT/9tY7o32c9rF6En5ma4efUQPxLrf0
# DATA XGJ2dCLkFq4s21Tzpx/jpC7FtOb92MOGXvXP+jhwuF70tEO2bioTSRUD2JuTLnoD9Ecl3v2wrd6JqvMx9ldv7+zk8jSlmE7DUQdV
# DATA kR8veDg9YLJTXd2hauf5G+WOmuoqjGk0UbHT13d1PH9e/kh+0Ddiz7fcxIcSt97pUrFsqcej0X48SUZDtTfcvo+mc714j+797PMd
# DATA uXJ/tC9HguykzleCsNijGvDRZ/Xa53SzicWOrjRW1lgvn8se65cd1XjOk0k4DS0HXPgrJuvSacQjOweyVywWI99fwNFbjuQW2Xl4
# DATA WoLhC5P5C0/L5blLu1tqz4pcy963PFk/HaWzMYYrml1Y0VSJwn982vNjSpn0FLxjcJteU/D8nfnELG+tH39kNduPfkxP4tTqSTHT
# DATA GW5XH3rOihlneYmGx2jUVQdQTXudDbdRyLilRJMN6t74nB/KHusQlD38NEq+EtQ3aL73rWgsa8J/ibUlODa8oeJ4vZF0nuB0Df6h
# DATA ykcPTg55+lSQ+XKH6yNOMqDg0CkLTI9M/5IKEjuwqO9VtDzYMpjTMr1PLRLdFvoZXFJ65g8fNEuGYrqY9kPsv5Lmanq/XYrsKOKL
# DATA 4shSpkvpcQTbJZwcvsHCgsnkkIXt4qe7W/TiUdiZ4UC5GcnRedNUtatvzjKQSu1jZcVwr2pu2fFuelt2TTOPaJ95gu4kSUsghG3r
# DATA cAq48pOPP3j4k/ff/c/eL+XbvYf37z7WX+7/z/feLXjlBEgPEyanjn7udTm07BXUPR1I5Km5ReEwXxvlmhoo0Q5Ln1DBbasqc4Ob
# DATA ZvaSqZ1wzmjFU9u1rMQSFdj2z3O34b+tLtcSdJfyFD4Vxb2LjybXS1mu7+KwF6zLEv6q0YDUj54WFoMuFlWV4NB1f3ULT5tv/DZj
# DATA TsvLaZpd7E6S8e5dWFzLwk31Eg3Zp7ujhN5zUMTMNwZIJpVQqOSKKLkt7tFMQe4sDRCxpCqCJ7XNq0PRrQbfYaboAR8/44sysPPB
# DATA flSAs2A6m0QfyxbK3ceTmTp4rT+K9blbLRdk3ZSv7+QL0moxqlC1EQU/1Xg7f/tmw5UOc64HXNlCN+sm2RLzYvaJTe1eUuwLZdHP
# DATA 10er+rFRJpkeTqdhp2/H9aPFUlv236Z57q/NdHUyL29gb57fH3Y/8wuBWAZsQ8PuHE231TdlJ986Rd5ak0yJ1EL2shxA9hLzaw9b
# DATA PgZz3QNF22TsYjTWFNFkKOVDw1gnyhePJ9m0az39xv2fvf/Td989seToSZolLXsyK69AF9ebEHDYUTMAjETbqhrzpAg9t55hl+5O
# DATA 9tir/4B/UUUnt+Es38eh+p3mAEVldFOa9N4Lq2KseoZN+KVP0G2wxdSD/A8eTVUkch02n9vYziYzuK+k4lPw5BtPMJQ1+xQYTu8+
# DATA /wMhVhPQX6oR/+Ybr3s87UwZDaq6WtthXfJ+gkE79Bjd42H30gheyo5H41M4JqNmzhB5xM79+5iFbb2fYB93ViM7xofe5uu9eDKM
# DATA ulsoI6poH38Mc+Bjst92va2PP0aJffzxlkRaiu+auhInOMU+jC7D7beZ/69SK9cCf87/B6+g8/9dxX9/+YObs3Rysx2PbpLp4I0P
# DATA p/1kVH3lhz/8IQt3CK8Wiy+yMIY1Bqz4YrkiGUcaeqs3cD3UZpTHs63BgLqFNV5BLFPUa/ob9jTpz/0whW9Qf42hDzaxnIBn9yfK
# DATA CqL52p9N44H5xnMI8y0drPFChhPbCTnvlJz2J0LAMxeokeU8lhzl2WRAMZaeU8ebrvHkjzoWXjzxZPY+k7yWITMbPdWwQJl81+7g
# DATA YFLTnMdrH3K5mNJgSx3LKJPok0it/yFDZNaZcmHp9/50vDcJu9HPoHagX7wYFzMuUd7IcIVdZNs0N0ozd5F0r0sSom9Tj7J2D8pR
# DATA PycjvuWt4VkO32F5bHjmiV2hW7yLamtHhyczizH7StW0H7t8dmX6Iu+Y4jTMVE+gOGg9vZWfSnH6cXo4xCaZbcuY5GRuHf2fR197
# DATA R384+uro34++Of7V8T8e/Y4+f330Z+/4b+jDH4/+5B3/3dHXx1/QtT94x786+uboz3TL90d/otvxw6+Ovj3+8vi/0k/89J/w9ZaH
# DATA yQPMeYmBGhNVdOSwY2kIS35bvqTK8ONJ7MeJbe7xeumudpL0VjlCIrI3JJ+7s+E41b9FIyxufhymnTgWowT7zDDA7lb0DE0cMd0C
# DATA z4hZ0knNcodP0GeMzdS2lM1tyZ6g2O/mUrTEaMCUstOnIttG+Ci6lXNO3EBzTUQ5XxmwVn+AKeUuTyc3mosi03aW/dwbzKA2k/sJ
# DATA ccBW5G19D6V9lGg3orpjEjFsTAtTSbHafh26h/PvB2RA0CwsHzkzrf+417Vm7bnsU1P3h2/YU/c33nl4/97jnzz8z/koL0ylc+mw
# DATA 35Z/bqmdrZ5lFPySZxeekcSioZW4vqacKXPTNLpjNuImxz+q9izrx8oJZVzf8EAp1TW4maornNrbr93KHGQf5b4VP/qsXKj7n1u/
# DATA 77z2YWnnhrrw0WeVQr2KuY79aqsX+O9H31Jr/x/Upn+N/uDf/n/23r25revKE+2/+SmOnaQPQAHgQ7SsQIbdlETbbEsUr0jZSSg0
# DATA CiRAEhEIIDiAJDaNLj8m3ekbV3KTSt2a6qruntS9H0BRrLbi2M5XkL7C/SR3r9d+HwCUHz010+kZizhnn/1ce+211+O31Ab/Qu34
# DATA L5Nnf8CN/+wvigN8pV5+pQrC5n9UUs/Ukw/Us0fJs6dQ4mP191OtqkbOR8rALkCeFGQS1GGkvR4bcFrIZgW1mDWVfG3z9JNc8V4K
# DATA XqFZdWkJWA3Pq64AdvZSc9BZUm2l9fg8L7+yHEzD//XsU+B0iqk9Al6n+B8NT41UzQlySDX+p/AO+N8vcDK+gPlSP599+exLxQGf
# DATA aH02JLzPfI1oKXV01ivJazXWM2PxIvxenbU+0JunsDpPoWFo/zF089G83TccnVj/818//wi4uF481gNYWmrUsJCWGjtq6/BGiMOD
# DATA /wYXcDVOesFE4Fh19Bp6u8epcu9ytW5XJ7N1Spd0Wx8bW8oXXsg/Wdd3wfPxt+Te3y3VLxQLajMumb1XafxDWT1dLC69kbJCN1CB
# DATA U4XgqtcD4KYjVBir2T1LK3B5r1TSCXn5mlf4yd5qXShJzVpxxtD98VadrU3Eg9EdZUM7CX4Hm/n5b559UTIcQHY77vxHqvAjqEgV
# DATA U5zh2WPgAcwfVOUy139+/omisK+APIFy1e9fW7NKYIWxnUxjXanDTpZx21MIX3Z6TKjTJ2HGXsAJ+bPaWmrJExzUZyzbqB4//0QJ
# DATA NXaPWdnExgRAL7S5Hb2NsTka1vk43bm2vl7W6cPloQDXJTXfDE6MpeEX2qxUEdiMSJi8AvCVZrBAy4os4TmaOFQx/LdWCzn0obzk
# DATA wll4KP2ehvH848iqffn8YzUnSMZwLH2KtPUJ7dv4+YWn0xXnnSJjNWFPaCKh6oBkn3+SUAl4qCmBlxu7HVttdRMtjPr32j13ffON
# DATA 1Ipd3K1M/624gl2lL8FTzz8Gzq5Gtr69WTabcQ6C4BEV0vXt7cb2rdu7tYvLK8t3e7c3bm6tv7f+7kZje31r40bjzu0bNU5Vg8Lw
# DATA g+b9dvUiYDv0UmcXpuZL1ZnG7q13NrbQIIGDIMl7c2t34/bW+o3G376329jZuHZ7YxeL8B23gkUbx+2HhYsgrLv13+3t3r6zs9vY
# DATA vn3rRz+urdzt3Vy//ZOr61uNGxtvrV/7cePG5tY7jY2t9as3Nq7XEE8WjTG0WnBR9aWw2AqhPp61xHCdYfhaEdDw8Aa1IEsV6tel
# DATA V165+EqwRP9OvNMwGyLN578kClMUrOqCl/S9uyimAek9Of2iym6eUbBEuKeJCYTF1SnSoKIoOBBVl0FI+FwRzpeq30+A53zx/Ncs
# DATA DPKbR6JPiQh+3F/LjFcwVviqK2qcTUKDuC48zQ0AV2Ov7sjnYN6Om7bRTH2gIeimGatN9/bUV3UErMPvclm+uK422KBWsOxng3Z7
# DATA mKk7zv32cNhRV/g0NaoPQopETYdYZ/vgPdw5oOABxKjQfrHCQ5P9NjgJk9IDhRRQ+db8WQPH1nDmtqidm2Ap0wIpVQAnsvomdW88
# DATA 3G/UoOkfL4Vlg5PrM2Sy6lxSlKN4zhMi+d88+x1yVngEvBZY8aegeVBbQQkgUGlZSj//lcOqneMYF4H6gE95/rJwHnjEO+0RmMmz
# DATA yGRkREtMibyZpMLwXE5QaPwS5Zo/QedAevAOlS95QPCP+s22fhAzYR+pDa/kC3XAwUeqOjitYMKemCWJzzu7buT3bZ6Z56Pgc9WX
# DATA X9G5wZ0IhkUnsL8ALIpLJ4pAOSvBRa0HCq4OIOvqgoqPBZd4TdQ1rUAsxPnGXnp9fXf96vrOBpxGab1YkW9tw0vhnfYpquhKSaBs
# DATA 9NrTFlRecXkVPWjVWgGZ/hlXDlg3MsMnJICAjAYPjSxNC6okS8U6P0ucjhvZivshf+rrsr544C3SYpDAS2D9kac42xSeaN8qXBFv
# DATA F+BjroKeQLBN294Nt8llRJXrZDghoIzzPBfIrmQMz2JQBmtaO7+tLTU8a/vCWEihpKRptN7DqApW+fn3bLHSIbTOwIiK05u7Y3KH
# DATA hAbCbgchftTs45+yNBRkBU+ww9J76tk6fSQHU9HTWuJnpLWcxBoDAyao4gr+tKHfVlqsdOmKDfc/6Y97aLGtgfpNThVW/zAVgFRl
# DATA DUc9x8Gkm9vrVAFcRN/q9veb3c3t+5fkoddrNThNw+pzmTGW7vVj6VI48UzhAEfOQbusZITEA8UiToeQl61HxgsMFKmMe0roLixK
# DATA RWQKAD8uONJ4/6B+GIvbvItrQkVCvjLI7OL4YYVM8kNSjKl7wueoI38aPR7wBZ0CV0SOeows9hO83tkcIiH9xBNLq2YdCM62lxmJ
# DATA HRI8Ay9+QkMH1VT8BuTXvNMhh7tZ54B0y+a03O0XZrRuZ1U5KqCn7QncBa2Dq5I8+x2dvI+x67/AF3/isX7Gq/onXAm8v1yDG4Ye
# DATA 19bG7nu3br/jyUuxKZaUHH0eL//O0IGywMWL4B9LguMBidAN+8TzBHsWijM8roKWjMwS2kcg6qoYfEECeu5H6ANbXQg8g84mDvfW
# DATA WsGIqB16rmJpYn0hH+C1/22C93C6nj7RxlrbvdNR2ehbFEpSH+Cd92nyzsaPa++u37izIXoS9cDzxsGbgM5xbV8KSF8JcfKYQxcu
# DATA BlGHIlXDlGFEe/4l2tQ+RWHrK9JKfIgXdetyxbpZ0ubAxetP6RyXEnRnldEQu3Ncw9z7iunp1An2rqnqz/+Tr32oLaWptdYLn3oD
# DATA UF//XF+8xWte9cy2k0rchLGfLkz1fXY8tPny7bqvWzdZEHJhGj9DFvdPoiMK+BjxYxjTVzR0NahfR261ZtuCpayRHTdXX7lkj6bV
# DATA OYKIxZp4AVS4SNF40lpmYLSEpcP9uGkPNtnB8bh3DzYZitHd5sl+q1kVix7mW7BiC4qlZD/19enUowrFIRewPmdc/P64/ZD+0rYa
# DATA ijZtwEDUkWq8c/ny3u+PQs9dtpp1KSEJsbwBya2oswXHZRgJmH/xjB6AhRo+UD/hBBsYS+LO2+tq5nbu3NwxXBe0jAPHqD1HFAhp
# DATA 0KjmoukMdnMuBQgSjbGJo/UECf0x7VEiKLUR9GFNplgY7pI9Doh4ID9hh3yKF9IkSS9QDy+gU7/XS1mT+4g40KClMfNeolOkB7bt
# DATA lCLgZi8TOoGLIKXvF8P+AxQFg77bTgtFUpugs7MtdeeaStQ6NMuH6N9aTJKCtzpFcNHrP8g3lIgZAMV46HZUosldOWFSX1kyDB4X
# DATA rDZ+/nM4QT5WXOsLi91i4sUazuBSzA6BVuAYKcoLJmv1NGAWQOBi54iO5V/8XrKERr0ERf80KsxTr1ijw2lEAVvGJlyBga3UeW88
# DATA wisUa10BLwv2BB61/Yfizp3pJyzbOAW1tKJJFtVORLW21EH9wC6mogBDDw8xsnadStD5AFRa/o6+07vXg4h8De3KX6ReABGP+7Wa
# DATA T2IWeaGqXRbDXQF4JCtAZ7mvNMFJk5OO9lc4j8X49ODIOA4fPsG7oTWU/OFvIaQJvOIO0Dyk7nLL+ZBKAvgy5IcYFjrEMDvIvQGR
# DATA AWNmsKI9WV5EkUvrxWK8Smu4HoUUzX0t+iUeBaIogB7s2WEhPG1AZ4cd1bMhuuly1XWK8IRWke2Lu4YJkOMu8Ri4W85K6G/yqHLK
# DATA txZL7HUOSSSwJmKeL/3ZAB3HHmcKSckQh6ln8BJCjexRYhEaPZXHMbRbad3hrvIB0REQB6qCbvcpR6AvQ7jDxlhdJIHykD/waHe+
# DATA DfX/8oHKLPm/Kc71RyUUq6vy8380XIxUlYqZ411ZSWfqOgqiacDHkQdqDkmis3vFGjinoGsCYW6PB6UbKGaz9OZ+1u9CzjRrgvhL
# DATA Xe8SPFiY65BQEnm/ex+zAWWNYbvbHHXutxujvh0LBYKAUxZNqmE4lSPSl7W0MkWe/yULxMbfj4T4x2BhxZlFRQZY7/Ey/uyPcO7Q
# DATA reURzvdjy4wog5VNg8wqPA5ndxiPrl+rutVtHe/4HwI7ze+wK6a7c7XAFNBrj0fDJoBFECWIRkLJtRovBpCCYP6NbQYQA496EMZL
# DATA uZK6zdP2MEsgW2vSPBwBVnm/h0li0S30CgOyUKA5IarohrSlJuZgY/ibnJjyXeW0edK1j1Lzgp5T6Ec597vc9+p1PSRig56zlGi9
# DATA ur8Rcpc44moa1a9ya+6+tBbCXAMtykJdIq7QjNoDD0FefQz3UB31QrQVf7rsxmjjuMx9FDbcWSoISWk1OZsYTYjYHG7tTDM5uL1A
# DATA Z1R/Zvl1rmT7CCXap7g7QarVruyi80NpA7bJz9lR5AtQMzzWRh42UDzO4bdkaaPr+6eocyO1JfLiJ44iwvWEMYsVs4syMJHsvOAe
# DATA yVJZ/IpiHZ5UbtrJueDcHPh8ix3h2Mnkewkj1xL2EoMJdXpldHbV08v4Xeo+f5+AkvrdlkZmQnJa8M/UWT7X0UsKCPWodvhvoFB+
# DATA /pF0oBzcLSnCXuQJaZU9ps3+5RnFQjJ5EXFzL9VzDvY0wzl5VNSaUwpkTZANTWOuV4RBFtDyCPpHXLw4/2w4x07+XIiqweKlIhN5
# DATA PTBNa6f5XPZDkhM8tsUmoyR0lGuhpFWdIwJRyFiL2+hvglAVjpiXryyd4aiRO2XaS1nQpvXeclv2ByHlo9KM/TJ+7ZUSeFOhluiN
# DATA P1/nuQSHg5zj5uuupe45ajcwx5I6GxCru12QmAwrWLNr8ATYhKTVx7J2oPqH65BtbTrDE+yQhblS0gDABFHvTHBSoFiOTup3asR/
# DATA QNMHGY0eiZtqEopPj0NtlCT9dIlXb+45LgEY2UlWWiEXCNLPvQnYu8N8GyUd93WceEwZnCnZ2mGXo8qUbTN86xosHaaASAntwU/a
# DATA BKZNUNnjE1snZM8kslara64xXgrOYp3z95h9fgDEsKlm7liJmqYeu5PDzkkTfajzBSyre1zcuyFKJWxJnE6/LzDrgF/Y7CVjVs7I
# DATA cYtM1/USEIZu95ny8/jL7YZD0WakZ/bg8gOkgOzcQCX+x9y9XnJk5Lju+a4VLGTtEB3kfxH979yGSDdt2hct+Nat6xuNnd313Q0d
# DATA D7O5sYM7lpkoQgDBCcudMeNCJXsec52xPJSbyU33mxotccD5xByK9ODYp7WNyjdfWmFhHC5z0skAkNoNAiNVXxY3MPL3+kLi8Q2O
# DATA VYKJ9Owx3CsBftHBd7YdJJw6UutHB1/DGfjrZLn/6quvmhuxnmU7CPx2m5AiGB24fb/TH2fJ5s31tzZKyTij5AfgD/igbaWE7o1Y
# DATA 96c2ywAQL60aCc0u+dm4P2omP1UkAQc7LuQDjP0ettXUjtsYYd5BZCLI0NXiWyyGZYwHJqScYw+JBZS8nYfuhHV3j8r9zC1pawfd
# DATA ycSb9Pw3QDlI8Su1mNyzvAXCcqXgzqZ9aLvNXoPAI0Gv3GBpvkBDK9EsQ1z/wXEHU71brpyMK8IMoVUDkhbFAf+wVJQNqhJf2GoF
# DATA uj2YfBLiQaUjXNU2BCqwWM2DDmCx4Zo+aA5bRp8Att98lTCp1THYhIczrVwgePwWXTBshc+fyTpKkWKPxMiboJT2RF0+PybPGE9L
# DATA hH4iRj3+qxyfQs/iy5MtaFcOTFwMDU7xYUroDEw4ex+gr96/+/0I/JvtPe84l5BqEfr19NlnZMUGJZSSqNGQ9HFkKvjCAhdvjCCJ
# DATA De0+xSFjTne9VPwwd/T83h1/zEv9QuGN6t0K/Vk8WylRsB99Pc+gxf2TnJE+RPNFfKhkZgrHJ7TVMAN1yS0Ya/AF+xu6R0Q4Kf53
# DATA Lzg7fjXFeQ2KZOaxZ8p1+o1I34xPgk5rZMBnj5lE8Vwl7RbAo0Hd4wcFBP5y3NIr6kiCOKi95XqymKwV96prnpgGFQezAnuC3kwd
# DATA 3+/ZKwKu2Y+QhHm5Od5Ijwz0Rp+SNokHDr4f0yyQV0hvD5ziPzTHUCT1c9pMjhfyp6zYf0rx56TxFcoyeM+Zu33sN1xYHYEN7wOX
# DATA DCPfSCYdvyg/X7e/KAUtGGuST6dWIctnBfML2D1kTubUyfhD6p3r2tk79VthZ8kpO8AEBbs2d4DYM/4Q2lXT6YbXPhr+1NQ4hfTN
# DATA 1f/U37j+zJlJOccg7b4GS+FX5SNg0oJaizF/W/ytdjuCaZBnegasQuGQLD/kgEpjLZ3DL8XxbqBY7X9EHeKHFJvp8afAgPNExxP6
# DATA nIvyJ0B/MQmHs/3gyQ6JVwBH7G4e5yXZvlkSI6c1JRNRQS2goXe30aR2ejJb/m6x3+lK1XPdy5xZDubz39T80BRo79c/Y2DhH4JI
# DATA jq+QJX2M//3o2WOWcc47l4MBelXsUUIT9k2v1UzP0XEvsHkzRTiR7EB/VKEhP/6tCduiuFxq42+Cufkfakh/wODKR89/9fyfmXnL
# DATA /EhIQ1Tr9heKa1EVsNQArtMfIcV+rGp6EopRn+uYF8ZzqeVEjbGL/fY2BwxaALIsKFxcFf0zVYVq57XlH16SWTk4JrrBdsi/juxu
# DATA dxE97S56rSBkaj2cld86I84hiqg2+ymefOiMiA+sMeTp7dnFYopyXuu+cy9R7B3pxNVFXTfqUVgCUkai5n7V5nzskjZDZ/mvVpSu
# DATA L2LLvHzJdPZBoMcMWJeoMrVuS9D/eez03Bk+dqwU3I6y9gY4+W4jYmSxqK3/KJ+BKAZO0xXAOLrXPs0Ke4tcDzdRtz+ptB+OQBU8
# DATA n31ZfPls9btnvdAXaai9GribzW1cn+PgCFXH8UA73VPRe5+RaQTdUMn6Bx5hpMyvRnzdgs5rD2Vh+ZDOHSfCsT+nFcUHUjM3ko6J
# DATA wm78SzZQKP1VjJ0t2tXI9a81+4JK06eCREo40+6sir8yyelYnJSWUzzwacTG7X4ugOfzWH5wQTWgbq6NF7Faoos8xQVGdxZXybb6
# DATA 2g4uxjOGBuuspNHm2J5accp3dx81Wvx2d4LZAUqGgqAW4wOeN1+Ox9m3tS8U/2BXTMCXq7Ta7QH8wYoqy1PQCFRwsqcl4fIcLQ7a
# DATA 4ZdqwcM8V5wc/4Bfi5P8l2hWg8MdkSkSiJVSc/ZHcMbBcFETIv78YznabYwESxiMOMHEpTbZ/DWZlT2zwes4dgNaEd9aXDwIinED
# DATA UGxR5Qttlsg77R1xO49W2oeHbVQQqs4XRHM4i13NMyJd8bQx5et74MefZDwo52kf1tzVN3eLR3nDRWBqWFvdPRogPXfirMMQJCoU
# DATA xCA59cJYC5HofZehc3EPEcCZTipCvev0jdWmwmsBRs02hdKmNgGXId1gGg82rdXwipLLvM9x7UAVyRcUkQLEZqKdOFKNQ25ioB4W
# DATA VHC474RhufQV9aUathX9d0AABeL1VpQzZEhEKS/G3+Bi7C3XK0ONVoRPyisav6gqZezlsNpCNCT1a3Q0JLBw+ftnDHne6uBjtaYA
# DATA +A+430pGeYiOcs1WC58ogax92LmXRq2Tz/49d+fCZv+Fon4QTP8JY7XU+nxOUaCioUpoBz2FjYJbBAPQoByCaX2AHpS/su9MH1sL
# DATA w+uwxxMIkVz4l1+gMugPCun+uNOFZBloRLBsPrvHnYxZCOCEgAmhj3B14OKECQC0iwe8Hg76XTJxw4kpsoJV3xBynrZ7QB8EPsw2
# DATA KMgd0FM9AsTNLgTvqAp7mNxAx48BJLE6ECvhCG0Yfxjn2eJiLODRl75Mkgk4Q63rUpUvbxqUMAX9fvr970tssiZR+5SJcV37/NDa
# DATA DuiUZZayuxhWjDf5eqzPnO5DlSWYK7sedjKlz9y4WVSM00lhqcNJLJDexb5bcAPqLTk57HQYKi+cK/fojTKG/ImaspbhGeEU/p/s
# DATA hNBrlzvn2uQ4RO4oJTe3dnbXt65tNHZ/vL0BywrcTO0QZGSExdsnQP2D43Zr3G0P04mvNaT/Ffb7/e4M0mMuTJKwM5/Cn2u1JK8K
# DATA zYOKOR2wZl7NB+tGoSX1y9qEtAupLSH8onPY8jyBHuEbPHa1kGNiax+RAe8zxKl7osTSpxwe7HhPTT98CcUWt8WFJL0S2kZCrasT
# DATA PEpmMu1M+zjfjKr917U12HXRCvlB1cpugzJlhLt4NNzVR7ZDxEZ/ZsmX8IWjLYMHc6vKZgueX8UEzydxTBo0M3/OMfozhOsprHsW
# DATA +5/ByOkqdtBt0l3MaXEqa1Azqr+zGTrmguUXsT30EgLhxMWW6XP02LmxCJihFUUR2uaNafePsDYR4IorQuBf8K0YjYNfitQDlj8C
# DATA 5jsnxXtUf+ZOYzVBfhM7/CduIIV7OcZbro1lquOngNHVxIEjNO/VSBteSmzdaG0PL/Ok+ivW9UujQqzZBazsUhG52/JBRng7AFMP
# DATA DI/2l7tQ7I4qxbJBbsFtYvSEdGL0nTl1+Vs+54ttLd17907T+5nmd4z6vTwp67/XJuU1/eOienH5h839uvNE/l4hPzndWJzNEKrH
# DATA VJjPMDDiUXK+8+EJsv9H5BjxT4CHIq4ABj79kyBCYi9nAUAQNsOyQyfOtKdENVmB6B2t/q/6fqMoS5DnJmucmAbdbC46oBOcoPTf
# DATA 6mPSrKFiyqiyKAsUOHhVRc8i0b7qCY0KusW7FkrxnyX3rN4xnlfRrTARX6yZWnzUhAuUroZEwZ9BUEeuJcQC4sWLZswX33bbJPTH
# DATA y5Nd+uPS5CfsoH9XYpuxW3DJ9QDAdcKdUJ8dCWeVsCw/YNqP+ooHe+U8hW8p/jVo3sS0BrDKpuMeJJJ7pDtgR1/BiaL1GegIFjPk
# DATA VNV5oO7Of8DjQY4P3FesfzWY1OWyHeATQgnlrrDpPvjK2PmTsohC2p34IIAwMzgf9zmVSMxhEBwJDUnCL8/bCYFJMIJTv8t8yLU5
# DATA PfFyI2X+As47YGXLPXLjWuzQ5AidnBUOVLBK0lDqeZ8EvtKusUHPyEEAUMlKbK8VV5md+zICwDrPBH1FATTo1MXC0ue2ZnuK2dp2
# DATA Ut9bpI4ZrqtkhkUzWOa6aFcKwy8tv/Ug+khnWM03JJj4iRADCHYEVzEjAMfFBhJ/Bs8yQp4O7CLJZn6y/cOkyhn8R84b8JjO4SkL
# DATA wP5ij6G4YRJOECJC1OuA7pPOKG9Lsvmj4YIMTd/FL7ol5om1wDq8KAsxOEcC1wICqs4dNxsnHbJUB9GaYZAHdcqy9OMDY+mnn/Oz
# DATA plnm/ceaexHUXC51OKg6xi0dJ8p1SJ9tQ8/1H7cT7oSu46aEIS6PReloc4l5JWJz5B8U+5hKbUxvdAunyNO+6F5Pmj0lgbcSUHtY
# DATA ueHYaZ8aAddFSFgO/4obue0aHpPc5/QYPBcyuVAN/1ICBCRoP48TmyVo06PzYJh/hzuXNe4CWMZCt2uLNQeUUGeOrdViouR6/hi9
# DATA bAlDjTyNp7DM6bNGu0rfT6CC0BnPEkxi0nuQZ9t2ufPdzLwj2XG2rTuCr9RyDu90AEpGB3vGhYBLnK/Bm00nsU7EbMy0bI6OCD6r
# DATA f0sGjghgvuI7uJcmMc4nDgCCCd+G6tsNCORqEHuSQK4CB7sAszpX6L2LNEb/ODBjPQMfDm3oDSHtufgpvBn8qD2Suak3FIDP1ZgY
# DATA 0zyIpHDLU5lZEqyUMnJ33YAniaw+f9BmEE2nQ+hwViIxmz4AlY8QZIY+CyXIAh34NjscBJnOwToDRCJ1o3IlE5ePBoOODHfq9pRl
# DATA tV2P63nCVUiI84WO/u8aNppPMxQ2ysrtJtJDtw2W4v6DHmRo7DUH2XF/FBq/bczn9H6/Oz6R48a4U41OB6BiSvc7vRaay6jTVTu9
# DATA IBj6aZ2qiTs0FtpeKHSd+K35FCTCF9LFJa6nbdVlP9oBF8shTVY9ErU1cvTHxGUb0TB475roB6nT8OZhNGYnFy0urdFEv66m3O9I
# DATA DFeQfhWtI0swSemXHIONMSX9lCAo8aUctrvtZtbmvNTVhZmOlx647OvJ2nKgadR3654i3GHnQDuEqj3cv9+mtJGKsElxz13w3UCn
# DATA Z5754cREruFPHb3GbRbzeyXxZhRhpmPL+EMnuszVfcFnF5LCcqmYLCaFtaTMFz/1vBhMNNpSCnZw5cwYTj9sMxhCyp4uJTMY7Zgi
# DATA fjKBp9GC66rkYDuPmkeISMp1VIYWuHM19YRbwVAGjyZKZqU+r4ZAylxZ0FVDDbPXcSEXMTUtoPWZ67qg6iqqKsqF+8Hj4hv44o1q
# DATA 86R1ae395vDk0pp6iOfEkQfKZGZHkEc1SL7RF5UsrNXgpb/+4wEBERdM5W7yW/PcTv1XSI+OD4aVTt/kkVoiry79K6Q1PjYaDKBu
# DATA vDm1OKWbNgNFlIqaT7AxHwkDiYuLobsdurAteD4zZ8bjTPug4R/lwbD/8NT7WaZL/dB2ULPc20JXN+PhRk5vk4AaDZrY3F414GCB
# DATA 0ajzOWLEHXAsz3YHUwbrjrpuoOHbRWyd5t8RjI+gQsBSbCQlVpeL3lzISEtR8Ar/dc1idrFIH2IdK0V7Gy3pNQXnlJJonF46fZvY
# DATA m8a+UtOIIUMH/EF3UMrswpPI26SZgYOefwJmPqQBSUomdpp/8/FkAR1ktULRyTHdsOBow5PWrdfO1NEw6bvzv9Pty1Ft0D+0xG11
# DATA gJFEjNhrNRKgjJwnlHu6A7xWIuie6Hk2ilzdk8g7ewrjkA18JAzvMTiG8et/WDb0yrPkZ6yytihVEXiFO6jCsBepXGiHsinM9wP0
# DATA xy7iul2XNoBZV6dgYmIf6lKpFkwMNx90ej2wR0dJilm7mVaHsfMBP8fJlTNIjvPai+E3SM/q84xWv5kvLtZeYz8WXhXMjYeHzwTs
# DATA 2H6TC61cyI/ttd1D5GlRjkAehrquEGZ4ULHT687sEz0zoQ80dvuIn4RaPGy5GnFYn4tgclstRqjo/JQ0fctQ//woqzkp55B82Yhf
# DATA OxkTLY1mCzzBu5GMeJwV0He1NR609CEVvhH3y2VpyZYi1Fgr5I5QET1O5sSBx72OxHpb9N1DI/WZspGQpkQoQyLEPeqIJzDzltQn
# DATA zDOmgqo7K5tEGuosZwmryl2fhELpHPEVc5FrrAPOxJ6LLr2+YO+7uI3tNegPjzBRiaGvCt3CXFCX6aSu6+5ELuryshi6vftb5Fzb
# DATA g0I+Swat7FgRUK/EbvJyKQfm50xMIRxGKZBCQmEqddBRKCMOg6A8QZfKR0ruIyWEKyAWwkGVAskmFNbc9lzvBIzZ/xxbRFkqL+qV
# DATA ZsijC+1pMEujwv8GOF1Sg+/zKs9f57GEQVLDZketyB1q9l1qFbGU2fXVxZOxfbQlmz1kbftncjSuxl1dH+F3NAXqwxI7J6FxSd4S
# DATA pXjuBgJhbBuAtZeRb2PRCEx6ukrGUBNTSU21xsSMI0vfuGkEFst8q3XBwFTtKqWLpqQSOo8dvOvzwfvmYso3JWwyrjWNohawBzzB
# DATA FnwLqASp58BxLvQF6lyA5RH1s9B4Qd1uwXPvCbwcZsLqg3tOEMP6/FcQySbJ5A3GLL2xUJiMwYeJLQ9NwXMsqZ4Lk9Q2pWNyl2/T
# DATA TxNRGAGmgUC9JVKOktqRuWCcqfNq/zRpN4fdDspYzIszOqPbzZZVXR/RHgfqDt8cMYJjR1XeOWmrr05AOs6Om63+AxdvthLCLLh+
# DATA o0v/mV6jSzN8RnWf/6d0GZ2D5vQA2GnULILnM7oU8xh1YUltaBJ2IXV3Q0UChN26qhHYXRfeIOamVQ2gG8y1wt5I7JPc76k7WNfP
# DATA 8BAjDUdbIB+6/TH15feIlj+sPyEGjCjecFB7kErktGLlOpC4FM2UIR6FA3L/Q/sJWkHVXzm52n5Nz85HFXp8L4z0wgw9Yuh2BYZI
# DATA YijLd3EKwIMciK5TbPAUzpAQScguaj82hU0FsVq/S+AIPt7hEBQGmA8g5moGaCiuG1IU1YlI5ysLEycfPmUKEIQbAfjEHYAv+1Wj
# DATA 8BCOeBf1hEAOPbWEhydiXdjNDS5sKpbozW8sWsZrrmB2Wp5S2oKtoJpisrLpq5/4OYbRpD2jFnHnCUbTC+UPmZI7xPMoFye+KSzt
# DATA CoJ/Ud44df59pp7+SeLnviIZzAPSxEcGKddJ+uF7DPda7YclLQm20TTY1AjVM2FzYtlwXk8uL0IOHPzPFMdwAxuFLt9Pn/9CcsD+
# DATA gcaqHrjpa9EFB4w3EZQcyZ1RdXtZSiQdRTUJU2ZwhjqYBCh5QhaV5f6l5eVJ7sA91A7VJ1GJIoq3NyU2qHcpIW+KWuCAX4z4EUdz
# DATA apQkPVV+qgk74gWXXOs3VE2204SQ6WzXlEN2PeEKJ9NcKWxJtCHnkgGko3PJygSK+OlK3K05qTJm8jxx4IqZNdCL0rIEVA1TsIwU
# DATA 1ZgjH9hLdfwc/0Wk4ESL5XhTGll+Q7NkdTsDaT5LgNckkN7rVG6lhEbeHIKyEXOmEpo7VmrVBbNfSTYwgRgIC+qzDEHf0ROs22JI
# DATA 6wEAdmAjLFGgR/eoEodZD+WtWd7t9l6Iy6GMoP2N3Lj825YvqwrifzEoEUL9z++fr2Wpb8w/Ke71b4UYc/qvDfxHUZuTNt1JfGXv
# DATA sHi17r6zGAEoxeQe3ht5IEKW2GLDFKBGg2AM3GGRSqvVyfD2W7Cw7S3dpmYojGkv0i4Qs41mr+0FcfOCFdMVsSGwPDnbhKBV/p4b
# DATA 6LksD5onUaOsXOEywRH/L2GGcIQ49bzQOVSM5x898h1IbS8MSp2KH5nE9nny8q+01gW72oC9VOAffAL0h/cItNpVFs5vPqlwFaDh
# DATA MwhOUY0gl3TUgboD3IN0Kc3x5bey3ic4cwSr9DQ3yVeuxFQum2MuBwEVHtS1mZsfsFw657zQYdCgM9OHtir5DcPWKshkLCUDawr9
# DATA TOPIfR2VJT22gKgpcKXoK/qmJyt3phiheR2w2SeJpQKcPcURVQrhasQheefL5czjzYHLkK2oX9vouHGdkiiCwsHaVUPKCVPXlUA+
# DATA t6GN4dL5Ae7nX1qBM5wAwtOGom7S6TG10Hhn48eRbfD/xBt+QqpmyG1LTaprpF2Poxk4Q6igkybDAthikMW1AzmQKZP8k4mHVoWt
# DATA eDABnpsyY946rgDVRDvdmcsguSXT33vpZksJYW7Fzv27qrYM1VFHqX80bFpIAXv1yZTs11X3jIebfWe7P6Swm4H6wwAwofv79q3b
# DATA CBG9qv6Xun6uWAGfhKoLvUztsxPtLBU/EtmR1XGRKrngBoQwkqbaEzEKUGKLm1/r/GRQ9nOdgpa/CaOj5PubeEjsYbzUXJCGueDp
# DATA zIxS79JB4rD2YYxBXcW8YfhaDN6H8POscDDfTBZnT1zVZX7FOMgX+mO4fhiTfGC2qXBshRg7JXivgNzgcSAuF6Y4gBZfFHjL48UR
# DATA EMOwd7EvpqEaBu5KL4pUGcVB+5ZwKv+z/H9fFHZUZ2pxBdww5zbpYz8HDwNtJvzNs9+VEsZYi6o9HXinbwE6kH2XcaO7Tlt5+Hvm
# DATA ytXXnpU5+6uAtc+J12e5gGvX9bJT3jy2vrTuqup7ze8Q6c/lgtMh/dyyCzkUIdI6Qe+ZFqsvsOdm4paeY5fHz3hC855K0MY9ZYpI
# DATA 6ugbhv2RknfIPVHtpapUsad+UFyy+oMsq5YAhvcIfsEfTPLr3rNkDmSFcOcGmYQ/zZdLijE1TQhbHdkTUQzMmQHKe2jirlhRMLUU
# DATA OBz4wtRAXWDGlFOyHm3QBmaK1A5aK70QeCMjU/shbtwR8dJ4p+vnGKCY6WDhZEDkfcHrXDLOGLo/cgjLirPAoyqO6afQSstfnnPu
# DATA zxYX1aNSsrioa5iEmdNLznZ0gLLU1wXV10EX3fmP1UlBkgX81QB6cyXSzAijUhZMwH3YWQV5IkbOLHtAecUJZC+rEETZcfth4eJq
# DATA cUHnPkDxKgbL532hSHz71s7uW7c3dhrb6zs77926fR0V/NSQFyRhFb6zs3EbYyWsQ1G/vH7VfeXX4mEIHlrHaXVpSX5Uz6Qbk78x
# DATA TLq1X31l7eLqUn7tb96+tbXb2Ni63rh+6+b6JkTpp8ej0SBTdQOpmRVJt9e3Nm6YYvqNX+XOnauN7TtXb2xeM4UdQWo87GYFZ1XN
# DATA ysPW2rtchcvU2+9tXlc9W796Y0P1buPN9Ts3YGmUlDFuhwO5ubF7e/Oametm66SDviTyAlYsurKra8Wgtvc2rr5969Y7TBCNtzfW
# DATA r2O1UbpghbzaqBCgyMSsJWV3ixLBhULyoDkatYc9jLP7O5j4YbuCKNRt2PlFDI6rVRa/n7pym6SH5M9L2AswOlZuemyUuwefjPdN
# DATA ec7f16gmAYORyg67zaOshlVOyV+L9V+oIY6qqiFkVxfwlc0c4BNmBgj0ALyAJhgDO/fb4oBHP+RSzK/cOEfMfyQor35KJPj9cnp3
# DATA eLcH8K4vn8utD3FJtV7jCnjxcDYo1n2aE5aTSNnI64DHDn+QKZElN8d0M2ieguFaDQ6sDRX4G4xXWfvSWmX/0hob02RaBPaJAooc
# DATA R+lI8jeuG0/ae0UXJYff7d1jgYEdsZrX2sPRdvsEds5PH4y2x/uKb7/DiPSqJ9Zr+KnewC8fMJe8Xt+FdSdnV8e2UDAvSsnu6YD+
# DATA DFbFnthPQbPHfo6IUSwpFh9hAgHS/BkAuUeAGAPIsB+iQ/FHz56iTprUs4jU9DSe15Qp8/BlLdjUzojeJnd7pkO19IyBWxVNv8w0
# DATA /KDZGRFiCTLQgoSodU7a/fGotrpsQoqtSAGMdVfs4Caij1AIoVq9VrOrJMk0CiwSnnysP4K6ruMTwXhwd45VDJokXRP79Kh17RzC
# DATA Ed2ekrALQ+tVyWwJjGoHx6qlykCtv1ZymVoCQAkguuXkNaeMZ6p/rZasXFxZfnU1ukH/gE4F4EXwCO5+bqKb6Eo/St7e3d3eKRsY
# DATA HR3w1uOU93ZvjBGYdVnt5iGzTEnCW4b/Xd14a3MrubZxe3fzzc1r67sb+LSy+Ab+q87S4F1q5dZW1e04zAuaCQb8+3A4wWD4ympp
# DATA y0Wf+3Ag9wMvS3iWdSvbGzcbMOzGqK+O1dv4dwE6oY7eYrEiycLNROHBAV9Sku8Go1w0+GXhoIlWNLghWNNZdGqoMPwOHibJ+1Tf
# DATA uxu3N9/8ceNHryz/UB3PasrWbzSuva0kBudLdY53TsYnVipe+Hb3xg6708Of91caq+wp3mwpmgMiho1XOemrKQbftwKcobwXyeR0
# DATA DKaUoNBrugoLSyVAVuuMjpMMtGsjmRTV2x6Y2NUNoZCurL5aWVb/t5Lqk8wwAjWewiqEpT8sVFZKurmy3xVIlNvMFC99EEkLDh2Q
# DATA CXowbA4a1JuCKk1qufawIXyipoUrqE8xrvEwT9BXJOlTDBUHZjVot4dILPvqlj5Ua9kfnvBBpKkGGJiQXzX3WmVA7glj8QPwj3PQ
# DATA rsC+CNEg/yTpSWzgSrXgZdrwCF//YVrMubVQ17M2sNNu4TB9a2NXsTDYR0srlRUQCN5WU1NNzmSGJvDsml5KdbPugrsASA7q/0P+
# DATA NjyOi8W82VtdXgY21kHdDzWv2Of9wisrq6KnK+6t1IHO1paX82fIYvf2yXlrh49N+wjdBIch/wyVK5AhYiCvrNtuDwoVvv3QMrhs
# DATA xU5kzGvwAWJM/zmx0C+/pKSYzz+5Iko1Ct35RPIs45qWomwZE6f/ByWVAVspCn9lUjWKNR9/cR68grmDZB3wLVDHlm2yn3kRRBlG
# DATA vU1TPHulDh12jZf3w5QSEAAcULKMu3dZXarw2JQvihNgPVfu9qyie9VqPbecI+4epmlKOzM5O1uwqhj3Og+rS/ebwyW175a0Entp
# DATA OO4t4URUYHNDlQmqXBtw1+4f9LtXFs5ocBO5pKtdj1NhCPoKWUmybsM+4iOtjbreqR79sgGCfc7Xg2Hnvnrtfit9zRJk05VV/vci
# DATA FQFRaTXp964sWEPA21WW9A8Pr7ANRB2TS+NsuKSY0rBNk7J0PDrp0vvmeNRHrznzSRu2QwOBJteW15Il9Z+K9UGrpS5vzZZaih+V
# DATA r9HJXAZJtHyLLqSKJrNe51BJ1d0HzdMs+Oo2AKYM28Pydl9N/ylI1p2DEXvylR8ct3vlg2E/y/iJU023T4qQ5O/+IVl6CBMA3jJL
# DATA QhR49HU7EKynjojGfr91StLR8hX9/mg4OGiQuEKHSnJxeTnz3gPbm/YeuAP+pa7600gQu4gkSBVMJu4w1Cju3q0U3njpQbvbLSOu
# DATA w1JRjUadbL1T8HO+EnwCg4VTlbwSku+Phx38z1JSUwuF5dX/U/uF2cHhsJ0dF2LuPCVt/RV7pj71Un341lI1/OW0RNunpu0bKKwT
# DATA z8DSvqYpxxrqPUZ+pFpYwRZQq9VrjxqogKCAOG7JPIVDkx8i00BPTcUcuocQhNNN7XdU/draRXna6e33x2pp6cVleGODFdl1iuKv
# DATA 4NRtXzDid2HA8HzM5n0WtD8gJ/dnXySuAIrX4rS4MEsF7var5l5zdM5La0WCjlFeBDyCKMLtEx1MEZGMTVjcpxi3ygCi30h3Tde0
# DATA /nAPT4BYhBzrK/wljSxmGI4EoXTUBMXSXcxLoYIS1C+T9e3NkrM+gFHN7iSPkh8Nm6fmKv0lR9BJThU4zS2fkM6hT8sRsJscaPff
# DATA YqATxBtuqfvy+vWb6rrkJqT7lOWHjwEPG+70H9nxVJ/SSpsohhjau3YRCwJMA1zcPK+zfL1St390RP5oZ2lLHWvoFpKChqbMaXTT
# DATA /kA8QM5SxajLwKOh0MVl1I7AIyyqHr2SMgOEuNu+AP4ggBS8HvcUE8zK2agP6VrgY24eAvDpr0BBqSP0z1zDt/YyZrtsy3aomQTV
# DATA jLudk86I6un1ub9nadY/hJ6tLK9dfuXVS6pD6thtmQeTyWQ+P6nmYCDJy2jozKUlaY0k7SNXVrOkkiq5WC/FJGRYrqy2d2juWVXR
# DATA 0lSR08c/Y1DG2h7boMt0Z6JzD046Y5om39asuqRWeUmNYokf5NTcaoOBMWv0ezXbdNrax9lUYmwLbUcIrsRYDEqQ6I6OT9OJY1Ul
# DATA k/jsjybRbtBrxEZU/RgpCgMfpPTazevlnbc3bmB+rAPIflU+zHZQ9FJHPxzKXTg0YepWlqgO9DzHJItqTqAHK8totWBxAok6I4Ow
# DATA knzQ1+kSHSzDUWOgrvr9Fu2FzDYPhzwlMNqCCnKg3lFOmb1UM5C0HkuxFCEtbR+prlyurKUvTGR0hTw+QeGrlqoL3Mk+1SYWMDXH
# DATA uz+BYd7ZvQbraOhLemhEKssHYkpz8yzg4KjRyUD2O03Kd5Lvf//MMTNNknLLeXj96iRYzIuz1nJ1eWKHbSiazJlr2jG8cao/LDe7
# DATA g04P2OO8ey1vMqAddd5Y3+PVALpZLmdqq2CuN/xF1n0AmSetND1V/PekfaLWuTxAEZ3etdU2wk2FZUDqpX7Bb69r/A8Kvn5xReHI
# DATA 5F999VV6BRwJ/lrOHVD+0hqnmLKS+7G+bI7+QH7Sr7mylu+cxbZUKTWlDltCRmYlRgoZFv7rBCmFonM1P5EviXz5VsH8L/EmL/pt
# DATA /0XgoRH5tCZiAHiTBK/BGebycilRUvYk1xeJBbDpObtsE0ZM7qJcdqI6ISuFIzM9JTE3jbqwZHu2b07g6laP799wjULqJUmjRjDw
# DATA 6ts9kT2Q9nKd7qI4gpFjawp3tr8XTg3S3CFFvzjvY/suJiYEKwwSw0p028YP9Rc7nKfvfoJzVPs+tGuznHbYhvill/nINuOBvi8h
# DATA A+g1u3x2v1ysjI7V5WFYe519tyBWcFQYVvr33liurhSLlQMMhyoUvRLqVR7/crjMK7O4zMpqRBhYdYUBPiEEYg2injxUCJ2UzTBI
# DATA w621QOZGRsIFnyLB8I5fzdkr9DZnV9Db6qo5zdxD/61b1zeu3nkLxnQy7o46oL4ZHQxqyyAEMNGll5erl0EhADf3Kt3e5c+lcWsw
# DATA TQqIC63B9rgGvaSwBjCuV5cUjSxh15f0q+qwr1OIl2E+q0vwX/OMVKzVJTfpjNe4RJ+dWRVhmJpXjR+6pv3FzyjK37jqJ3a4m/wJ
# DATA y8y46VVpemKpwEfDJl619epFFpyUuXtGWGSfcmsDR5AunEK4G+e+wihRFrwRWYUDB9aLi5ws+tYcsVdrdcxFnMdYmkIcSm4Qsohq
# DATA 9dJSEnyj7pqZ81H/aCkbD2B10P0z1uWQaYPVeAnmQQSvWDeY4+V8fdAftrVfcexzxFR2StXjUg0qkmANY3RUd+N5IponPAbIpmC9
# DATA L4aXFqHbuviaBiNDs3n+koy6GezVvLPdMpHkMS18W12prF42fCtGnAvn4zJkgID9bbMZ0sDD00prie3BWAgZznTO9oJTc95aZ++A
# DATA c1b44MEDqTBmioA+euzTYln2Ar4of5x8ExFURk02O4YqCKIKySOCtwNSmhdmBb/8qv0wKoyKicRQ0SSylMTeLVV7u/oVo4pBF9TW
# DATA wRxlFTHTlD3jH57SXDw8DbtLsVnVRPS5KWYEsXqKOB46E9ScKjL2srHl0jtDkK798JOpXpPnunjZAeVnYYLkakLmCfcNjT0Qn6dt
# DATA opxkwUSHkCi4Av9ZKxSLk2LYQx/oRjjr1HtODMbKGa/tblVztfykkRfHqBrphB2dfZGKbJLO3ivlaPKLMSdoO0gPiELxDydYRLBj
# DATA MB1eCSxn/Qe+KYntNf1uC7j7Ay9ogDOLOAJrAasr2v6oIF6rGpwQLVQt2CkNwB8adsXfvrfbcByWU8zvdX2T/kIvXdvPFv4W91mA
# DATA VTZNevnQVTlK5SO/Al/kUsyZGB6aoAb1y4lBcCNlwtgiNWyKknipBvNHrpHt02Lu3f6/65ygT5/9maOIMNE2BtNCmu1I0NDzXxNQ
# DATA AdRMkY2KNAjrh/xtD9QmUHTSbhX2CifkCAjmZwiB4J87lPTHPLiuLo2dHu4G6+nt91IOzMZsUBwjeBOb46SsRaGYBvUCCaehe0R/
# DATA GNLh3xbVgJ+RutNDFJpkLoIdjFaXflZhWuP+QOK3a3d2dhu3b93CFUEVuj55VW+tLFJLFHerKkfYYdR2GWQOeSUgsxZ6GPaHjZtm
# DATA ZGyhorcQ56nHaZbXPOPMNgX+gKr/XnJLslWOjofttsFILEMaI0wBhQcwt3jSPE322+Aa0G5Vkg2EU5E4Jq4QSwIG26C53+l2Rqd0
# DATA SSyJizLaG0lQU6wC9WDAZxHUYdRnTtHJBFrRQCXQGn3dqNAofoJMtTQGfYwwmqnB4kCTMHRYCTwazdQXg32pS1qrKRVAtA1YG5H2
# DATA zNOLdcHjhfMqElflh+nZTUE+GKafeGqxOeuj3Fxig6SqVzwxcNjuNhkOjYqbHVCRd41RnzaURLjbuAtwqPsfdrLGXN+GiZN18AD3
# DATA CtYWjM3yoELJkUBaWcWXL5TWza0NXEu5LufxCib/iK/AnixUPVyLcBfjL023FhURow/4QIy9I/jCJ2SM/gKVuCFjj+TdVNd12r43
# DATA WY8HksFVRayAswS/rzUH660W/3V92B9goWHnvhKrwURbd05i79w3EYToyBHW5aOgNwf2QSNhhNXkDB10m4OikoXUpR6Jz07tdW1d
# DATA Hfgc9t1EjI6CF8QPzpIBo9HRquqsceMJYRGgN3TgcL/gH3PY4C/rqInEfMqImU9KRTVdffK+kiyMwmQyPyewm8CpzG+jfO42dGbO
# DATA mXOnKNTi5PkFo84foXxiKqhqQHHwq4zvMrhJYr1pzjW5ildpUPbyjTmNqHIgasxS+UQLhkobxMCzfpcWJhIcCElXTfbXGJKFn/x1
# DATA focQAQaX9y4uuKnGr2caKriLCxSNVZiJEe77J7FWsnBOKI3i/PhRNhpGPgjpzPFSpmILIkOjwJAnD0TsPP8549EzH6WHMANfPf+1
# DATA w1rR27OW2GqGQho/c4C87Ytk5bj90MngezYV12WGdgQ6ws/hz6Kd01KQXQ51zqaSZtI5uUqDmD/EKyNRjs46V2bylt2W6U0WKQwr
# DATA hzeRS4KVRtW62eWUBnM6areWUtcPTXoZwjSoZYIgBilQgutOjc8dbKWKcgUd405jEGci1xdO6JB7AfsXd9cEVGNRG9lcOWYP04/H
# DATA /MrUq4/caxpnXp0O8qAlPfJGxtUO4B+t/L2E8vJ1k8LSDycpLP1hqUzc/KqmYl2REKipw6p64ibMVHUpHnzQBefgLcnDutscbvYO
# DATA +wDDiuiP/Fs4L6Q1ROVHW0ld7VET7EMF8DgtJRA3BdkLrGCa/ghxu1VHmiPVDS6hetfQe1zXQqCialaWgTahygq44zjqLnkIiO2A
# DATA 87q4ioSPzahHl5JFeR47QGGMfKXjniTSOEZdtFsZ3gaz5mE7QW85S0nPX1Ryew5hSNCRBTNRYHFtDNS+yZsgHFA4n1LQzyaIFhrF
# DATA +kzFuqTX6FFvDKmwv52GpfK8xjMl8EOqkZy2OeQTCzGOHAGRjqCdAepK8EpvluukczRkTsdSA6qKD0Z22nhuqUC5g0zmHFidBi5n
# DATA bVUTyMUSITfwi5Vl9T/u48svv3wVJiahAABSNXT7Rwgaj8TCGU0ABRORTnvq7g6Eg77rAHR5HzqtutGuqMoWwhzdNheSTXKAh0Et
# DATA WV7QUV+yByGDUQH+6u//tCbDI0PP8H3Kq91Re7Tmb2IMAuNp8W7rbfSDgSuH/5p4HPTlQi1Z8YKMKDMvXYCxCgJLpSteiJEyxoQ5
# DATA 1kTDdg2/VkJZc1+JbeNRmySztFJJCSt2OMryjos7PdyovXBXI5isxubAbqTF6JlGvehkJBOKa7p+zEiGesLUIybu4pReaSLuxRgO
# DATA 1BP2huun2Nhk2WqS+Z2hYnVBQZrJ64HF5gKupjdSgj7Mbjda5tgGZkbixE/7nR4mGVgkXUFsGq0PfWUFU/ocfZUZIigExQEUqbVs
# DATA GSdnynjxoojB1hTG4+9kzXQYrRFFJVrf5UTcy0gYoj0JJ/egT7hDl/uvLi9DsAgg6WQcDoKA3o3+PStZ6MxLLPEJtSetQeUtX4Wa
# DATA +zr9gOP2eDzqdCutTnavMc4ghRuvZuUQ1KWvORR6Ibm0lnf8mpneVLvj8LBzADFPgON7D5msErNOkC35G9rm+1FVnJzKfBzgfqVe
# DATA haOhb4IkqzMJUiLI1Zcnav+DL6Zb+fcAQrk7zrAwhAjDBmKUbEXDYzJtyd63kLLlACGzVSzsGLpcclYWz4L04X6KzL0/Hg3GkVxk
# DATA 9hcHx4oACrj+1p7Q6PArKyukOUTw+ZAYSU9Nd5c80jNB1rp0fL/tdyG80VKONlsFCJLWn5WSS6+8cvFSftQt8BusZVbIcWQlH6gZ
# DATA Gw3HPViNVk4kMc1ohYHwoaF4OTMtZUp8lVOW6ztU9HEcgQzvZ5XD7LR3UJByahJ7/YJrVcQTTFsTB6cxqcdSlwjZOLxX/U3uCaQo
# DATA QLewQWqpWdDdASG3aaPA/bCCrorsxsD+g2SsFmfCbaRHqBwsRS0Ierffbm5v4PP2cOg/Z+mnc4JhOWCBaYIWtbILTwor4Ikrxe91
# DATA ul2reKXVbFNsDbAt6zlefQWABKJCVRGtD3ci+4Mw/ynypPSChlcKrpA+jDrsSyDB8dDjMtIlfrnggbHpoRbshD922xUMUbdetzrN
# DATA o15fbfUDWBarsGqKNtfKpYuX1/xEDSXqSqbEx7a6BR64iaecSvwWtR+LlAMolIIFfGIc7YhXgq/dtf6422LYaCVioagMzAJlPHsM
# DATA CBnIfNp5Y98CaRr9/Iwot1GTMYCaa3biMs7KeK3Zw0uHOnS6p7ixrLPnismrZraIJIVogfIckypATeFtSRM64MR224rbbNMD3ini
# DATA JgC+KNYoBaBbNdq1iRWJ+wBwfmzaIJdIbGbQB6qJn205lGW/CtaQWE3Waw6y4769KQqgNFD9H/fs7ax+logxYaFaDo+yQ1dHnioj
# DATA in7zvWQ94VA5IYuT5j11X6QDE2L0wLTaJdENoSo6baKin42VuARZQ9qdAViLub6D/nEbERhlbJXktpo78DBO7rXbg8zNqGdWnhJm
# DATA KDbcHwMaZkUSpmv0FTUHBZu58juIE+aBinKyDvkb0D2chDAl7qoRtxt0AvBDQPuQP73NZTrlAEnpzjCzKFpJ3Dz94maL4IeCniV2
# DATA Xma2+MJU2xro2+NeD2WgSGohSmv3Kajn6E8Ej8DUOjFt3leOWpzzodmo6JhOiHR+H+cFg9IgpiQHZSWzVRi1vXWtGoefAYYRPmQx
# DATA 2ngxvGQrqxnp6MVsplC9Z+o5X+JRb44fTdOXWur2yJ1A3wIs3wtM0QRJjzq93J3qyhkAqIoJg1gXqagcp5wesjqy7rqv0Z6eapw3
# DATA mm2YfFbI5liRqb56Xi7H+Kz+BfG9P5lj+oweJ5hEO420mqYWA6dbTNPZZ4GM5mrhoYYK8UE4tqvebeM6MZnMXJl7Lcr6qW5UcKEY
# DATA dyAvkuKDSXM/A27XbR81EbpC0ApNZYac8UAj0WoJot7gMFV/4i2NRZaskmxBHqEke4Cma+SWXQQYrPj3rSmnvjZD4UBJ0sCYLIce
# DATA nNe5NoN/pcwmn9K+IKO+bYN6Gl1cSWJGOH9/YciDLyW1RzR/CkIlUFaF32j8rXwNnp/3aE/0kYtMQ8Ojbn+/kC6mRY9iQZfHmTgr
# DATA XcJNi6VLisKu6Wy72srppt8tTptItqoI4B7ksHwEoNgECwFJLf+iYdjA9vc4nNensU0zRaWotRowaI0OZ42QVXB0Q83TMKL61jYF
# DATA WIre3AH/PpckhCIeP//l818IKlUUkw5oDIkCfQNdhuxNAA7Iu4sHiyWzMPV2fkDptHsAyFaI8dgp3BsBmh02jV4Rs8z3RRsGGyd+
# DATA SGJ3Af+ScA4/raLnmavziEa+cfYMyXRwl4KNw+iKFpIiKFc6/XGWFp3HQ8qKfBrsKEIxI2x9qdk2oNP7uI6Y3s3pacJwabjna/yL
# DATA uwyJA9Hy6irtEEzNK0t4bJHS3CVP4tCixaW1CV4ooMrpG907CTH1hfA9xPgiyBXKiKHY6xfkJGUnmxdAFrV7PoVHYVedyQAig1gK
# DATA xCBYUq+WHg6bp5wZQhaFhn9C+Jjwyf641+oCssXcjj52oy/NpmxEPqYZy52w33qjfiJjptS+LK0+lcwDlAfYPoQgL4GaQM4G7Ihx
# DATA mBHYS7zlJ4/2E3dhVU90VgNEqeXss34H4/QjG5ApxWKzalPYGSLdciT9Tp2qyGlsg8bZp7HMjZW8/g+UZxfQ4jzIT0NjC9rvL6Nc
# DATA gLDIEApjpS1cT1DdpsQwFDjUtbhj653B8S4Z9B/Ata6fZZAyGXPKNYdkdei1H1iV0R3AciFKECk3O0aJ5sExJF2Q26RYBpu904RV
# DATA K+BDW7EUNlRLh5CELGwrkGyVbIDntyM3oNBuZIXg2LBcOOzP2OfcatBx2kCoIXLawD/ZExRUEwC+yajDVd/AgCEYqMRS04+qP07/
# DATA l1VuNW5fv7V148fJ+/RLBHP9YOvWm7du3Lj1nkuSoxhv1VpR06T7VaAjsb4klZX9JYP2gkq3oS7y6nIsiL2cz6gaXBS/lrM728N1
# DATA svJ8lF3vm5MmJ/lIb0vFyf/3we9QzpCkZ3a+ksROOy8YhBKRipratgiPdKzqHD75LmAVQqEqeP7dIk74KR0aDJK05wNDEyoWXQqt
# DATA I7DopYiA1yWMcmQhDx74TIuodSGWjVMml/C4cjEHskqzRaGatEHMJrIsz9i+k2TeSpELuY3cBPQU32u4Z3Uhv9XYl4w/pa6EyAxo
# DATA 8RVlYQLHL3C10Yfu+UeSCxPpx80Z++x/TMlLaHJo2ll1vXA3jM7BK6WktYLMQYt7aYJfBwzJ7obEC9brsVoB9VUfTn8iv0fIyfOB
# DATA ILahX9b0xoiN6Qkt1p00hPq5mXuazwtg6kjsQAa4rqBgblIJfZH4CaGfPbniwc7hQQTrJZdAL/kgJxyqsJHEah1mAD/EHfwhjvuX
# DATA gN1mnWyVRLDu8JRUpb7ApGMfkD5HMEUe5SQ9VAw8S8rdZpgjgRw3/6IK/oFA6XWexApm8dDpvz90MghiqBMCkLBD/GMkJ8pPKO52
# DATA z55WwgZTokU7GTh/g8nAuVKYWqRQQ5ms0tEoD2GGhmf/t0GQVZcz15sW0yCqKsMKKcY9rA06+YTI0vfMVcQZ1jNsH6nbDFwP4oOm
# DATA 3QpVqKtjNTloRTedepiQdliyRyUDjBhAUyLzetha40xSWWIgaXzj1yORCQYkohQBVNE4GmXJHlIZPRzpDF8U9l2SCO0SBVWXeBZL
# DATA fFeDPyA22o1icJkbufTEU5bj7rBzNKHRMTJfUk9Ru5YNSOhieYNt8rOSxBdy9SQml3k8FbjjRouM2VedSD7j30PiYsoPSAI4bvA3
# DATA N29s7MAMB8Kuldc4zL/uYUHbaaNlyAboWM2Ge6zoRmGdAMManHcKOOlFTsrBZxki6E4/c57/sgRc5+cmQfNTOx1rnJGnqaFMQ8NI
# DATA nhQNLRA4jsHngHL3BBsO3MFNLWoAvq4AY5vga+sKI8ZA80IvvmcYxGbaQ9TWol6CPvGuTDhVFyRRr/SEVtFU4Yh1eZHSaq+jj/MH
# DATA iBtly26GKFCYyam36C5yMa8dPE7lLE/cNFIarNS0oYMIzHlO4aR1Xw6b3bt8mSicUJiOf3OpCI60uWeC8VU8LRsmpPMHZ7PDmzlO
# DATA RchBjtqzevx7Op6R5v8xAv9VZUHmqD0XTUynCwtnzJuYoIF5icMnkKCJCK1QY57EZ3Y672AjrgVn51IQv6+O5gpfanlXF/eqF1fd
# DATA k2XmHg60QLz+0e3MC0wUMe5JuG8rnVWpRQDBOM6x3PPQe3xZidJjdc611c2ocze5NUQLcmsJZVdbhvsLabD8s+Jjxh/+ALVTOLQE
# DATA P3oimeGfPQ1lRmnltbDG15fIZsVwU+XFJRajgU5BkPZky2g2+mdPS6CN0ro7+gryAVnZ3J9EtXJhZ0EQ4vn4jznkUUJJY+qXS/w0
# DATA wTMt6Qh5Pe2POG0CiBhc8s86qspBSg7F3N9bF44nfIN5rPqG2cYTGDh26DO+QuBNxMwSXwjFRC9ZxLXNx9PeKTFBQmmf/1zuQmxa
# DATA R7WhllOsdFgswwiviEsvSJhGeiFVDsI08a5Ff+wh+oIe4d+V9eHRGJraxjdaE6R2bK3RUDJ4o1G0voQreqPJnxTS/qA9lDCpg+M+
# DATA 6EVqjOmDuZ5SDCXL0NDAiXApBTfCyoCMU2ZxG7+x/9Y5dTFOIGUkn+ZQUO8w3Rf8fUS4d8S/UsRkzo7LtFuwLCbYsR44XAnQY4KH
# DATA jLoZPOf+oT9KeTxQJyPFNQPiVGckYD/Um2wEinPrkaD2lRnTAKeg2+xZfg/YIGtHvcfiTGV7SQzZGUfXRDMKDZW5A/Zk5bzmzsdf
# DATA yjjorTMZmIxCL5dBccB7EOoNxYEhSjrlMtvUilfyCrCJLr+AuA1NbcZcBG0a9QTs/DbM6TK1FUGMmtJZSuib+56WOv89kxKBp0/t
# DATA C2ZMnlLTkJ2SIDJzeJTVQFM+dWyKtqZ1jBLfmtXILWkpmPTqT2vY7BSOFaylM3qKZKo+K0uayyaaymopknEDU2RObxLxyPpfvw4A
# DATA RyqfEPCBIbu8dBN1a4imzJytMMiyrgAzX1yZ+h2DMgWfUtaMac0Sb3SXJLctv3oEoZ/OFCLMec7Fdz6l3TZfL10xNejyyvLMrY8n
# DATA lVllnSce9SuMR61rpLez1/ZcMw2Y4flvOUUcN8re7VwW/4HSmYEBgF8VfbjrHCB8qBupxE/tiDcJ/Bi5WVFgx+JV8ilRdTU4YnTy
# DATA 6yol1hMK0Z1evX8uVb2oZLn52DX6YJnoqBSEMPtd23Ng/SxNQLvX3O+iygSykM6HM4JoJgZSQ1HR+o0bLv6IY1aSvAB4QUGVnfN6
# DATA YOBU0OdZRwHYSw1AZDBl1F+Tdob7H0ULdkK4nU5oRDozipz08vBZCwBGMKkBjG7aKFuEEMNx/vPNJhi8Y7kSjMLQWn5t4nQjEfQi
# DATA OnPHKs1TRRGUDp1KEWxir59OJ05bSDXTSw8a8LJN7u8Vg7wwtT5fkjwXsTMoRB64CB/sDXVQ0ff8oFhKYl2cc2qtIuLsBx2YPsyY
# DATA dGz5TUV88M/JNKbK2dZ1jIvZjvtSzB32eRbRvVhY6WKyDPKS8gtJ+JmFY3N4JHNN/MGflPR2n42ybWqS5dbsgh8QrRdmzKh3ObIJ
# DATA E140+IXVae5lfAbzBjS9E/59zFaok1jndOM8my5ycfI3tJjd83aLvf8oEQwiJXB18y0zPuHmtLcgAy2RyrDkqerNpjafmXgG91Ne
# DATA 9zATgukI3jqKEW7B94OG4RrmI+tG0HD2Z+AQPG1opWTWCDwXR3Lz7PQG45GDDIJOF1VjbwIhndwLq46rF76cRHkZxfwYTjaF1aGX
# DATA u4Uun0dm0y7wTso1LDUXBc21Zac2x7t3PnK1KHWubZqrbgj3LXXAwd/FolY3cDFK1hbkfs0waarqZvE2V7dkrQUldabn52IpWltW
# DATA nUY9Uqow62i2EK+jbJS5HtqfZow10F9N7yGXbnDpaT0NeQj+4C9ndMuoFH2RpwQQ9Ig0I0VipHneGeT0Bn6f9dmIP+VkFMoPkKen
# DATA 8gZfUnLcwa2tdCUOCA23DTXwK3HfIxC0tQHFatYGx6xH5TjLsXzGsagVu1NJhHauKlaYtjO1kEmY5vSDcGLDuQWFwQx6CRUMVV+k
# DATA 1+r0EGc83qTTxeJ5OiCa5jn7IOmgvuluzFwrp62ZS6aZ5xwX9JlNo4QNTeZ7mVKEG6LtUhyARSbz9IEB7s0azBLYOieYBCs7NbHW
# DATA 6u8KOdD0QFgvLFtg0A3kr42Gtcc4WrIY1KmR1R2nocES5W2YYt21AhbmQVmEQNPP0YsNM2qFcUi6I5I7E38UBiXJ/OEQm/7MdJXC
# DATA /lzUlCvWex3e88orPjtUZRxHKyftecgOXDR6zYpn5NbVCMAzSIQMUOHpImyZkjDPddzqNBb2UTKVvVHOBWs8TsE8FhDJXxZ5YTfj
# DATA pp8sofbHNNrr2+8ikxtdCPuhkwXAT/LwdU4ot4oNALHahvBOShQxo5o5TuErL3YGirHSEZiDzAaB8DG3WCIaO22nKCPUuoNNIS53
# DATA 2mEVvdT+orMig4/aNEjnAJ9U84dZN5W0GqgYOYVQjHkEZe2cQ84H0WRD8hWQVpUSHhruH5aiLVh10x/br4ox9Wg16QzUDA8BwaEz
# DATA 0FKtVqdwpns7KjxvkhBpcsH3/A90ylK1AzpqxQLghyVEkA9h4/NiAHzhQu2P+5yXG27ZFBdgobU4CUNMDVb8QP5VDu3x1ZlS7EJO
# DATA /hWxWVQ9hU9Kpp2qxUMn4ZKxjdNGPqnGcqlwufVAgrYqmS0NLyyodhtISo0GDr/RACJtNHgCnMAdcshYsOBwQsAVwMVBvJTqNKFD
# DATA 9vi/Pf+F2rx/IOf3HO+ema7g2JziL5igDcQZCia34GwQHGbnNBu1TzYoL6I9iMK7QBXY+1LyTvuU/4L8HfznrR3+A5E4/nbn1tZ1
# DATA hNrBp0U7KG0TVTOYRaLTO+iOW4J0hqkhsmrSw8h6HH8ybP+UgEU46zzE5Y273QQaqHzL01dJnv27Cdl7/gnBcjBMgo4cKLlIHb+k
# DATA kEeLL1MQgZs/5fkvAVHqXKvxV/9r/k/tsv0unJxqG1UGp99KGxAUf2ltDf9V//P/Xb508aL+G5+vrCyvrP1VsvxdTMAYHOxV83/1
# DATA v+f/Xn75ZdhIijuSKVdC/zDUTvLQkNKtA5iBw3a33cwA5YgiTFcqq5UfrlYWFnaPwYfXLvizsRLRk9GxOicQTY4DRBADtHMEaW2O
# DATA 290BxqEcA/sAnEL1tj8+Ol7AQvpCkexe2y4TiOphuwkgRWhGhRhZ00dO350cN++3Ve/a4FkOVstWRfWtPcTw25Y6UvfhKAWgrV5f
# DATA m6IP7EMCEVsftg/GFPgPwFkgURKI4QIA6c46kgL+ke7OGs+xOpTsTqffEcdx4nMOfpr9J+z/Vy+9suLv/9Xli/+1/7+L/6XjrM0C
# DATA dnplYUFthGyUnCXbw0520rzW7eCFm34lEwxowG1dSP9mgA+XDrBMWrzC3/70wcguBuLIg/Y+mRiKuoWda7e2MRHILUw6hUCuf98u
# DATA 7FESjwx3TlXgwH1n0awKmG9KOJUcwJz7I/CJ5/dZlR1Z8wuAqK+qqUMPD8c9QuYYtscZnI6FYf9BkVOWSH69/oPkr/8a/qlwRhcn
# DATA VtpuCL3eU1Xa6HHgs/bDgZqg9RF+2gOZ6v33E+fF65ht7zqI7MVi8H12oC4FWUXx1SOEtajxnMqT9993ZPK5vrmQrMiouChLiJkb
# DATA uYLzWXQ7xTWB7HhawK+T2uvRqvB3Uc30ZGGhCdH1iZ5xdU2834G7SIGoq4SpNiRtmawBaO1eWvq7veXyD5vlw/rZ5UlZ/702Ka/p
# DATA HxfVi8s/bO7XnSfy98rq5PtLFUiMjpkhYf4hH4U1cZAmoX8oSdNeIi0X5J1IoTA9lrl7Lbm4WgT4UEUZsG6M7bjZw4u7nFN0wKjv
# DATA WmrTdJqQQeWKgOkpuiFamk5JdnlxgoNbFTiMJTRtleagg8kvswpAXt3pdX42Vve+5AGcg1W1vXG8k2TCjS8tJbfb2Vi1jUmBkiYe
# DATA 2GW8kwnkVkkcM6A5pNFTPIQBYqKDEYGqh80u4Db0D/gcPUyGnaPjUVbRy6Y7rMjsJb2/5GlRVhgn359KdgJLkJckB8fN3lG7dUWs
# DATA lSgNKPoZ0X3FDrgmt14aKqVQ6arlhNprZgbVguZMIUIpw/RhMnOrh0SbsGalRHZt1Wxa+E+l139QgKiBleVkMbl46RX138uX1vCc
# DATA A8wg3BrVZK9SqdAG4oAdZ212QYTqd1vJ0bCphkP3s4P+UI180IfECZCzD0DWxkpsUuuAsMIajK2i1hZECqmtT8kGm0A9zQONyYbA
# DATA s84igwzWQTod0VLjGFkMii2o/D0X87DmkVYiZ/ZFaUG0ewZzPinhSpzx7FmTN5k4y8zMWh1JFZA4C2e8ZOrMG8KyVZHxAuZJF4KW
# DATA 1rc3rfiVTlMt5k0wOxx2+/0hMlAihdY6JrMBgGBMKLmCi6k/VN3J4fBvJGcAaNcENXYVEKDbk0QRlCoYtCQfhw1NismkZDlTAhMq
# DATA qT3d7B711YY9PlEjeXsHHCuQhqYw2Tf7w01iS1F2C4igvRYqHW3OGzyUDXXQbXZOsis2trHqFj0FiFC1CmS8N1WYps5092E78ADq
# DATA agBqKxwAvpSqamkxWU9ancNDgk5FxTpCZCqWc09RvGGrkOklU2wM9qKQcCVZXEomjumH+6ZIl/5CCzOd5UAL8IKPAH6PfLNmnwPW
# DATA CYj765s8laxGnf1i+P/UnWOzfuH8UFfVHo3eMfa8OIJPUefpCQ5nqx59RpvaJuFOnHG+I7VSB1B8rFA6Msw31RqrpVFMWrB+m8Oj
# DATA +5TLsQbQ4DI/NC9UO+CsqX2jxJAzlygjM9knyRKAujHXdoFk3jcqVNW7pCJ9o0Li7huVbNCFe10lBXjb5I03IFvQ67XkVdjjgW5Y
# DATA SbGDEeRDBHosaNkYkXuag8ES6t5piNmSCNb8UXlwlBYr1Jvto2LhLOpdqAbRI+iyHSTMqp4ndRBW7BzIJUigVU1WSzPq2SW035ud
# DATA rpKNq4r1NJYBo7XT6ra9VxfpVVDfBLgSJYynkavWC3ndKlayNsCIbjeHTUVSFCxNyeaLML0pRukdAE9zWwIOCtmDFLUraSACYoBN
# DATA 2/eZAq+1TarCY1xIKF8Cuc6eN0rg6QCb6fw9CTogIoEoQuwtcVJOhxuiWOBn0xixPU/GGr9z5+rOtdub27ubt7Yau7fe2dhq3Lmz
# DATA ed0tDlm0yWJfCtDUp1R3e+OO6jJWajShFZAoCiRxqX3kwcCT0p7ecmCk9SlOqWxA3GaKu1baNJV5eKnPPoNHiM4GxnQd4f5PFqYF
# DATA WtY+x6yHJmY8iH+Pq49/8+x3aJyLI7/5aCUVDPyQuXvYGV1Da3eyoo4la6SMAsZjZUb8ffQkw+1UoNsO7XA42vuUv+jMkEApRg0l
# DATA uSdPrix8B/qfhtn936gqeLr+Z+WVS2u+/vfi6qv/pf/5rvS/2yhHmbUXd1dMIQFqVrVv8UYRqE+cW1a7pW5gmGeMzUHAKS+tyS9Q
# DATA BMnf/WwBQZ7Bqafb2Rf7EbgTSJFhW/4CO6D+W2P9y5NR+2QA9zuqcDxUR9I+xV1JreC7AYf1gq6aUstyCDf5VqFbK7oekwb3sDUP
# DATA tKAgCZrfW1dv3Lr2TtGkTgMEwRblTWtB0C/ny6HkaZYBkqCWEW8QgJbpvZeFxcIbg0KVncbmzu2Ntwo2WK+D3ispCiH3RiwZhbEq
# DATA FtLNrXfXb2xe51MFYuBdfBsP5pJgjaQhEIsZLftsGadKHeBt9bRQnEThhJdffbU4q0emJ42bcFpd3Whs3958d313w8G8xqOJJ9Tk
# DATA GnnFzzWiPecWHI9uWnn8r5PqBp8wiUQLOzkkLN8BfIs+C7gUXf1BuBAzFkHA8olcK4GfIHdayJgcbwi+U+7+2tklt7umpPSYgtMY
# DATA yJ1HIL9hEKvLa5cxN97du5g3xS4LoXj9YatwUAR92EV4xD+VlL6y+irFoNlfFeeZju31rY0bJE0tUCp2dBGxs+pgmBh3BG4EzfGo
# DATA H/GQkMkkXBYfHAZvlD62k53mgmezcLa4yF4KEruIoQ3o9uDEK06CnWuq47l+gTwX8dlSnGf9hszV1vq765s31q8625jnLaPQS7tV
# DATA zia/0x6NOIO8bp9f6VzPfm0aARzZgw0Fp5uTvOfMIgqYuBvhXYadFsYSpz3wGyw68N7YBilE/d42T9rkjQq49LCrIYWwP9PSv1h6
# DATA jHRvvfyTZvnvAa7a/NmolOuKfylCnaSk2DvXpG9t7L536/Y7OZNvyDNJIaS3urQkqdJNyiuA+2MSRW8r+WF7tunJ4AUCeX/71m30
# DATA z6UocO11absYWe3rPyE9AvbD3scUZolRx9xHeYV1qfNUVSGnqmENsg3Vmwre3Oz1VpUhfggGOWs2A0WBFHAO1DP4Lbo5+S0ogfL7
# DATA Z+M2pTyBH4fD5hEKH7qwOnJ1q4iOS63hSzj8FW9YfhGW4w7spZqMRcfzMrVNq/vt3d3tHa759sb/cWfz9sb11Dl1tM52aMi6JFUr
# DATA Tr99+9bVDWBjSswivYXkhlWXifXx6Lg/5DtpNUmvqgu1YjMIC+Vf/95bf3ejsb69SSeNul6gJ3S0lJ4JhiJ8D6AINQWTYop7sZf+
# DATA qKxuLw+aw1a7BX+hv1eq9lNlWf3fSnolXnJ72Ffcup7oWYXbkqe1BFJHAQ3ao7E393FF8Ya+Dn9fI9iiLsQsl3RKt4w0qBD4Thc0
# DATA /K6C/4Vyl0Grqm7kohpi1Roq17O21q8dtoFxzJgjho5V7JMHCkDW5KpcTfHqq4gSdNHNbpW6QT9IC4eGLWm40r8n9iSmHwr+aB5A
# DATA B0ivAGpXEPJqy4CRMO7dy2p7dXgBbJi6XaDh4Fu0yEj1+/3WqZpM+PxCDV+zKetK57AAT19fW8TUFfCf4pkzaVci/ZKKVc8m1JfK
# DATA AHINXh2DwrYC8nkBn6vL8ERPM/qV1dCdjBLacnH19kDJwVRRsTLqk14LpTklzJnpIifP998XTS3+fqlWS/toWUZLHRWq6CX1SusX
# DATA 1mfRqbeGuKD3rFuFejERVPDk7KCr9qAQH9IjjH2yUEDiLhRrr2tiFmN3jZYNOftSc9BZImP4kjaGF6+ogRe4//JUfDhhBKyaLkYG
# DATA oMEqrkizbAAPW80zlVvfquqz2vpw2DytdDL8l+Pas+IbYljnfyv8r/pWdf4l9yOopxjrrt2k+gzK7S3X3yCN+Nw9XkovYAxi+87t
# DATA zWsSRSCVsXZdMZxioahVVmpdfH2VpUsiZ0YL9UzjFD8CWDKtnYJSX5LPIgFPf0pPo5opPBxKiSqDUGeQa4ESuJAuzDSAiMw29iPm
# DATA ifF0X2rKfLVVbeUKcBn0X8Irgyqw3y5wCIO5B/AFhg8dxVcoxrgkDlYsEuXfoMJLBrdh3zDw0bTDcnv9rY3G5k34byhPUVZyvvpX
# DATA dttwsW8OT69LTEiBoCogr6SkQEOKwCGX6Qp+2O8qBu1gpUtsEr0qcsyzqMQgnMp0mAUzUoEilHUaOQ9qtvhEOtLI+YulHDVqTGQv
# DATA 8Eo4GWNeRHAPUh2gLSxSef5dhK7/vpTNf1qiPxXkuk3Sv1gaFSQuk7qwjhg/7QPM/AqhbGWGlEZ/6t79oqbMPaiyLnhjUBz+i6KS
# DATA hzYSuNxjy+C42EMxwhqJutCohR0W9EDMbaU4X+cZt7pcJki+cnmgbh941WkzZJ+NwkW9yIeOyJsDfK4WFAksNZPAWy46F+JUrn3G
# DATA be9yK53mjv7T9yLP27JA9evXrm3s7DTeVDsWxFtK54b3dGI7oCc0+CeYdSGP+XCLimXdprNWfa/4cbsFOvb7mFie54S0j1eS7Lg5
# DATA JO+PhFJPKA50aqXLBO5neaxT8h24QSyYpHpxYCJOVuUCEbFXvBK+Y5s/rVojSyP7XhXAAU8WJIsE1GU6BSwHMwhlBQmdom7YuKz4
# DATA LY+bwJAE2CFaUX90DEDbOfW4uXT4Ll9K8COTrsOemArUBDjncsl/SedflLly0CawF4zQRdgcZykulZqMs8lkQed8hwFVvXyHe6l1
# DATA EcYLw9niorBiCbi378qc4k6ShOhPQdOwuEjLN4lclq2pE99gt2LCojhL0WFKdV0IOoWxq9/wz6SUBGRTYpoxR6V/b1TP7F7z+wYl
# DATA o5q9BdV5KXqImxC7e2dr5842qAf0XTPUBEEGFhtySt4S69cfYWBcTNlTMhC/8qlNFmFkFaVZgaOBpGcaKWh1UFMo2x9RMs0BDrCS
# DATA jpYHOmTrmfShZLUoL/cg3ktaNocVPXc68FLN4z9zTve1W1tv3ti8thuZZnt2MaTtTJ1tI1B0dBWtUHpdar4q31jz3hyNmsC9AG8h
# DATA pAzET065di+xqTUPUglPgTsyeRn2czItYs3qGDjQFqBmvOipb7PC3qJpEya5WAx2sx4CxoVxacdhBLFciD/UnfxJyPAL+KYkPoAc
# DATA IlhdcLmXJk5KhcOUafEWtRaQ+Q7tVZX9S2tsOcDv9lKKdIAkSZ5FgZDByfsQlWb8AfGEeo6sSH2CNkvyAe7telAdp1r8zvz/Ofzz
# DATA Gw8Dmm7/XV1de3XNs/+urv2X//93Zv/dOe0dqLt3D4yFEJxCnjau5zFlIoc91LTzVZALngHVRvkKBT7MEvJwZFl3+QnnOxRj7OFB
# DATA b9SVHwDOp76Qnzos+Bu1IcOF/0Wsxe9s/BgUlDt3rja271xVjL5x/dbN9c2tdGF9Z2fzra2bG1u7GPmAgggknRimf1d4o0ruHnvJ
# DATA 3VH9QvGN4HN8sVirLH4fsnG3KzfBonfQbWZZch23Ix015tTRcONqXogh9vrDE3BGYo6Va+vjw9e+hhNrZCsffZ28nryyskp+leyU
# DATA Bbk972Z37/7gje/dfbi8XL77cOXw7sNXD+sps7DAimd3PaWBNli1zsejZ0ZgHm3ZI+hJaIywAqRzlfJz2hIYFYTMBXBFKSVraxej
# DATA 5onzDxC+pBHqSiqkhyqknVavmerzpFjpQhJINk07t3MnMp7/LEB1TniwIQ4LaAXoIzy25+09qASAJrAtsPq+gtbctKKzZuP41CP4
# DATA Vw2sRTmKwCUS8o1helXzFxr8vBxDoKLudgteElm1Y5YfijfshffhL7VvUsA0Go6KfJUY6h5YjphB7Qi0Ebawx3Y/1RL/iVa/SysT
# DATA eVN8Y672XoDqOVOg2Kr2quWVupAxpY2SiUTLFVK/vJN16YqrCizL2jItSyWVyxX8piugyUDkjH+JB75e/okabKXxD+X6BfVoyX9W
# DATA XKRph+RQ5x8pC3BIJWQUsRxuxKVmQEEjjtxmJ1PExm1uFkmWKKnFNfQIMAJ4Mk+f1e1o/U24su++nUa23zfhBsR7FBBYtvqjNwGq
# DATA xduq4F3DM1GNObBqJwc9lm/Vv6hwfgej5dU1TnRuv+0BlhKsxkqYHtWUOr/v0Opq9GI23/piHrfmqOn7DFlDuJCsFO3NBsWL7jBf
# DATA jLZ4PaE+tRn+xpOIYHN0QX9IninudhBflYoOeAbGei+d4a323m0hymu3N9Z3Z1FsyU7vHqOv5oUc+oq4peUSmyalr7eKgRobZUmI
# DATA oTm4x22W+BmMrbHxIzVc6/fW1UAlehW+7fSONm95WzSnf3e2r6/vbjSu3tn5saPplE9OO+1ui/ker7a9tuKVhJgd4JKUFZAYpzom
# DATA adK0Es6bRBwEy026EgQsN4VyMk3lT/vWrd3GzfWt9be06kjrC6ekErbZtUlWHfBs88ph3KYFp0wcm+08FAPyF2YijuE60mogQJRV
# DATA xsXOWrDZo61ggooZLEikjpXktRqyDnxZhF8rl/LEE68uFtDh8I4ILnRAo6PSSmll9bJ2VHI9r7DZWINWYzzevK7za+z85RekF0n/
# DATA fGaWVbKIVUkQCF9YYgHi2k0WDDIc1jUxeaSxi5TvDTtri7/INu3qqYx/CGhxZApj0Tjv1kbFQyEwqdiWlDu9TgyBZ/ocXrt1c/vW
# DATA jqe2jXCW8HYXzaRdjKr7ztm8EYdgOfdgskBfh8eYO0XmJf1e8E0JmjijeQ+ilhccEZK4b7PEE4fKxQyKXvK8MCV5LIE47oO9eqwp
# DATA x2uW64mChPkt7ekfbr0wKYQCgu53QQZpu64IPRfw2z1C1q576l585+QzxyehlYfWVJqoy46QB44gRJmvlSR0cfXF+IEIQAa7kbkn
# DATA TyZTkVgKVR/wtk+bTas1cOd2Mg95zBeWkWvi/KNu2ihpMDASjbvoOeMpdYvOAcaV5LciGHNccE/d58CrhG+JNcXNVop7K3XH+VxA
# DATA 5PaqcPkDT8WXVbmX05ctOvrZuI+iARVctvOetOQxDqSAJUsispJ2vdPVn0J5JdBWdRfYVRqiFZdZvZLabAXevZbgtbKANck1En7Y
# DATA 6YjT76XFuRmLezm0Z466uVJV7dYjCgspBsoonFR1DqIu7XuifMKIRnxXWyni5FtzbTtpMVlJKovCLDI0ni7YA0OOtGfCo6vurm9I
# DATA o2IILTEN55okrEzScjkSj6pgB4f9owuLZN50WuejzNRXIXtkAHk7nWHTnRIyOltO9TED7BR+bvmVuKbZsKXDBLSvqICGNqtRNwmZ
# DATA Byqzp76oG08lO8WMc77LV74SdeGcxzqTojRG2kTUa7DkfNRGfSDruCuc7qC4EKcLTmDrkIfVGlUn4Ag6qYIoGAFxYj8FXS1oTAte
# DATA m0geFaqC+IFwVMFzJL6wn550sgz9fZzNdJbiYJUIx4NWFxUKXVSPuGfH7YfSgORJpPKd1kT2obE7cNgKYXrUMASAkbTgJsR3Dbw4
# DATA mduCuaOGl2bnrpKzuzmsQF/JTGIRQjarnYNR2PyTBhHufWsCqYVA52ILc1iJZa7O2iN+iNckWQJ0khog5MltWYNJTNtC3+6FpetQ
# DATA HXVoz6xjfX6J8e31rbc2Yozd7ChpnPpMOaa8ZyH1OeLuSb8FuHItI/+/MDudxkq1oO+Iswt5jjFTmOMLSrVWZ+XrKCHNlHTPxaR9
# DATA UXgaL47xY7k75ojU+V3PPynzx1IZ9AcF1bwfKhRIzVFvv7A+PChEDsktr/Oq+Q5IVEnwHfsU4IWxNT4ZZNrlrd3LwJmomR10OqT4
# DATA LmHW696otir5hedwW+QGkJnD/O+naeCgEDtIcQ+85N4kSHrRgp4lKrP9DxrLWcZc6uMO2pWN9zEoB2sL1p52vVccyExNSU0b/vjr
# DATA hWmUpPnICw2I+w3/6DAccMnlpVH/BJ2KrRq4cUEV+kR+iW7MYaPC2/Td2fnOv/FL6XkOFp0iSxSKkuic9YPqDhnLmVGGgYGZHJ3j
# DATA 1wpFOM2djlA9ruaOnn09lS7XS+kNQEVcW+6/CrAjlNIhI41QjmONSVR10ux1DkEK4RRWxsNwz+leNCuVZBzChybrN+e8woSEth4k
# DATA em55frwm05UniVkVFW2Raa5GJoHAjr0t6WOu3RufINhpQYjGTF3dS7E1QhdoS/ERatdNAwVz6BbjDUVEVot8YiZAXFmgI2vc8Q16
# DATA HlnEajRnPnPaiFNWIU4TjOzNtQcahYXptZvJnP0lL5WkVXP1lmLEaGbtDfwT4gCDNRTqGIIbeqbkZq7zvEtFqEwW56rmyQrezE8/
# DATA 6NGWO+6Rqn/h/Ad7bG7nXhxjXLWYqr4GLDr3hf81IMEd/7+TzhHj+32jLoDT/f8urqxcvOTjv6ysLv+X/9938b/vvbQ0zoZL+53e
# DATA EgRNDE5Hx/3eRYgSuzWAvPMJZ0aF0NFmz8BlBrikDnQkYHF6XoHsTtccHqG/3YL2ChyckjceaDJg54onnvymQN6/h9vg13YDDOBj
# DATA IGWBIMmAl99sv0Dbi3DhhTNTRaFoWm2aUnWimRh/4nTd5r5ieyESwjUGQDaqtBtY0on5sq22VJG2GlcoYEluhZKnpQJe2WohG+pT
# DATA AloQwDJ4O3c11qfmLjzjUwmVMJ8GtmRbB83x/dYQaxD074CRHDeHiEeyqvFI8IkNSaIewJlo8pHJlVaG7N5w8+0BGr3BToHjZL/h
# DATA 4fi23dl4FNx2Mb9xMTjNuch0IyWrE8NpsN2i5E69tgmzAUj9oskUEzY9nzIrYvc5sJRpNUutxl2q6SxePNga/1uKxdxp43yN1XEY
# DATA THVH7cwa7EL7BlMUnBwJp2l2O0pMysxG84POMo6oxMDLFwZLocc6llbCKb7WdhYtLGYYQl21+I9StiGJdjB3ncWCjIYRQ2jwYuyE
# DATA WCivxPWtHQBZsYqEeDjTsFhKs0f2NjvFclpBAyV7Dv5AX9X17V9Uy5RzjZzWHado51bzTbgg54KenHmgJ5PvFvRkDkdCelYwXS+5
# DATA zspMVCXjKg0mwbW1i96Aa8bvGqfq8nIx33qiUxblcAtaP0poN+pTCuIC/tciKVCY3VczAIza3a0lDuOejptTir7HVqjnHO5QcwnJ
# DATA 3SKxgE8kSs06JWgix1JtjEMccVFLzpz2VOcwOo32NQe7SZgtBx+oFt+8fWtrt7GxdV2esYn3PvYT8rdP/B71uMmgT9pGBiJdw4oS
# DATA RPvDi7PBBS/oMGvzfL8ARwW0eSWZYVB+weknNfO95DqyDMFEy9j3q3kw7GdZghkKdLC3DmEb9RHw/AB9KzFJI1f2U4Dhh1fyCcfa
# DATA EgaBek5BMPttEHzJl7NF+OjNk/3O0bg/zjgul6NoM/Zkhq9EQ2lPBgTI4wssbz2rMT1SwHv8csyQ/AUrFr9g1XPuNcv7H/YPqWmP
# DATA nBj8g5XjjOVQJZuJ6VRk3WJWFh14bDa80LKe3Skb6zCOSuC6XutRMA/1R8LcJx4TGqi/zS5Ty6WRr3QjwLoANOt+PnZXlHXrjemM
# DATA kT1LBU49CzhlZrHKGtmkCe+/AWkAHL97tVvG3ZFRAmZtAlZU3TRGaoNeR2Y0bsXOpAe4oHMINpuYatCROv8GwbR1Vf0HPTT4YZWV
# DATA IReqkkvNcp0SPh4fDCud/lK3PwI/6iUTLhzAwThOLtYkEClDWzNWdthWAkiH71Fup5aoU+UV7flTdceCmjT9uRYRwk46Ic/h68ls
# DATA 6oPK5z8/0W3M/PD1zGaJZ9L9qH0CDmqxO6wXQV4IwAcEj0DujfqBDpynQHJoIzQOyxtYSGiBpxcI2HczBNVpq4WHorfLgPhFrQq1
# DATA OR4P7I1BpTCaudZV/KfVxIarMqIp3S9qL3CCCoFgYyV2Q8JLlEZqFu6G+unvSfWosLdofVQnQ1iNYscPmgPIItboj0eDsTwcEe5U
# DATA beXysmaaPE4aFihCzQRZOUY5xp/EX+dOAU1btjagYcnBlKQDvEUyRib8OUb5l4FQslGffiIcioChIMTLBOwuDJ1ieZtS4hn0/cJe
# DATA U5pGjHeygHjazYyA+wtuwqMU8ruND44T68YAmSGff/DsMeAkJc++ev7R8w8xnSRkn3z8/GNIDpk8eyypJVMPah5c6O/1FKtIDrtN
# DATA HDEjOH2IKX1Z6uCPBfoJgZk+xWb/49lTgG+iVryMlGFbkCkE3G/6AHvS67Rb2KAFD5U8+0x9/xfMc/nPAGIe1nGt2WOIUQAxEhmH
# DATA O9pqtk/QPJbyA4SzsvGnnsTqZB7RZFcnS9WD33+OOZA/wAycHwHalZqZeOJP9SIy0UVvZTU1ol0WiJEyFBL9kyGDKECRJb3S1+FO
# DATA T4hIHgGhMRyXDb4lE/A0r6u/SmzSefYo9ZOFyoUiTDdbOEyf/QulglbT8emzR9Ja4UxvuUmRyeUzRPiCjv0CU0Y/AmD8EvXq0+Qs
# DATA 2L6TKjyE8U8qiZ2PWlLTP1b/PMaPARkMMp8+/8h1xjWbSzELw6XQSQQYToEwelDFYrtmBbEgIaSM56wVCwoBQ2+owcP6TLlm7+DY
# DATA vTHybMPqFmB6H2H6WEix/cfZ6Gg5hO6o0PZ8f5mB0yWJe3a5I+nBMGgN58INICnW7VnQRUWHJqGN8KJQdEx1gXrNHf5/d/Lf/klz
# DATA oK81EUwdGtKqlMhwGM2K9n2ZVThRvad3KnqsxKrEEA0p0I0eVh13kK4bpwOBnmQ6COJyiK6se2n5kL+Ed8V6XbBC2HpBcUoNsgYy
# DATA NBYqC/kRGXgb5IWo02FzrtPY+awa67bbgxohc8OfBsXK3iTG8BDLsgCRdObXQi5Qtek9bySStThMya78pljwTLxSGKIFOyzYrCg9
# DATA cVm9YqakflR1JD6fxqcGT2HqlFrIXIoLeUE2rrREBMMQaOkikaQIH+Vyr19G1cAA0xXoZwARhnwI87nS40NwTcQziz1EYIVB7PKN
# DATA FZ4Yt+D55jmu2V7oDd51cvfsb9VO/QNvTjok3d0aSWgyj8CyYGPiIxc1ZF6sUK4DOE1dNPxZEPOOVyxY7CotRfHwB3u1FX2VeQRA
# DATA jf+sO0X3OOV8Xa5Uzlt09Uv3x50uCD/G3c98fU44MFeD5wOCzYZoMw2Tllra9CruOkp7qLnTr+hrnaiwy5BtTNUfuQVOFhz3LVxI
# DATA i0cVQ88thLcE3bSYTTHzoFhOK+PRAS75ITwppD/48Q9OftDa/cHbP7j5g52fkG9b1Otrr3qZFU3ncM1CxIdEPMLAIYuiUHGv0Tyy
# DATA SwXNHgkYVhBrdE5KiQOtX5VNCFHJdjBnNdGkNlkIPUKwcyXdg+LCNEcy6jeRvjiTzfelmCvcb+kX8zvR2jgzpZ9as+W2YSXPszff
# DATA g2bWGBI8p6rQqMAE19PKlaAv5g0MVfCYLN3iyuUmXdDK5Z+NO5g+V8+3MEs/qMmu1zA+04EIY3cQM83N0a7JYs62RsUdr4Mwmgtb
# DATA ygEZbJ3o3ScQMeNTbiWRMP3XbuytkpXywMKFFSE32KVs7rfxLVlr0Kh6zst2Z2zI2RAr0+6Oh5aZ4xeZQzCuG5WpNs96EsGHjZlA
# DATA LFFfaqwuhOnlKg76cGRQpKzU4MM8cZYGpJqvSzEnORlCaGqrM/1GrfF6G1dXEgEJCWh5hqgc6IpyBOGIlszIuSYLZ32mYCQbWKYm
# DATA mAcYQWfU4E4Li7TohqYoFI2LsZW18fm8eUPLgSp1PyoHllypF7tRDG5RuqLvJTuj/mCAMGRHAvWa0aNKsp4Id8BMVZ1M9ZnTt6Lp
# DATA Rl12E0SFFX8lNYMP0cZ6/WolWFvqtFZpoWDZagurVD9ESIng/C4qyii3KELX5lqoyNyjz9GlBW5IIZe11ZzW56FjZwOVIRBVU7i0
# DATA XIxHREfYvh7aCzJ+p4lvlNf7ZwrN2FkY33TcbnYxPHr6MfA2FrOfQJFxFvcXnu9IIUsddwD0ocS3Unpy6ivs8+rPs4+gRzTZVACQ
# DATA LZ8vBxzZSLBYB3LV2V6zfDv5V626hHsGKy8RvR60CF+C9ozUS1/xJeYz1J3NlbBxhk4ijRsD99XWvRdbJln7mtqbPZl1jHibun6y
# DATA 8qTDbqmLEWmjFR9q5S2aN0m/n3lfM+D/z38ByrzEVj0++/z5x8mzP8KlDh8x2H90BlDDUFidB848ohv6CNWyf372FagDQTP7Behk
# DATA v0J99Kc8gF+fa2Vyrv5zsO/4GdzoNk8hRQZpP755pQVzjsVFEd7NEf0mR4bEhjRxJaZQdLDVSvi34/iS44gvVTDWqz526ZCd/0g1
# DATA sLduVIwnz/8nnljkTk+aOLi7FTSm1TDD1DziDVxZHx6NgZ1t45uCWBHV2GuNhjo2Go2i9SXY8BpN/qSQajU64eiDvqEGZJId9Blp
# DATA P1PiipikUCEocgSpFdvdFqkRKS6KxCe2e8IvMquREYtVSwQmg/YuMWQji011BFEZ7gDwU5KuoGkXxSY0gGGGk/Gwa6vUosMr480c
# DATA ezllEspljEuB8LrTQbumM3Khxa4m3+A/8FVmrm3wq2JZ/xQn1XOXJzPTNzgtJdv/wOEAWIi8qtRp7kl3+NIyL7uOCUjRck+J95HX
# DATA 1JLDael9PoSf0nI5shQ+xznTEYisjV8GB1fr9Wvo+8rV++4ZwcHpW8DooPwSLUCK7Z+Lz0a1wTQgw210wVxVMEhG1Ps9M6z6tKXl
# DATA 7IY2T3NOG9Gr24WparrQ4d98k8O/HQ07PtF3Cfylde1ai26op6F2CdjP1aI10LDQaCAFNBrAVBqNNOLbSewm1w1Rp754p306O/EF
# DATA 6OnbHrzqEPx40mf/f3vf+tzGdeWZz/wr2vJ4G5AA8CFKTqBgHIqEZU4kkgNSdrwgggKBJokYBDBoUBIjcSt2JjszlVSmZmo/bdVM
# DATA ana39rPixIlsx86/QP1He8/jPvt2o/mQJ8mKM7GAxu37PPfcc8/jd36FR/lndHrntLhYZj4w3N4JPDZJ1umWyPLISYAwbzWc6F+/
# DATA /GdoBCojiyUc8p9D7dB+JRCU+Jx7A5mHsOlP8d2P0VSGMpyQCVCkKwXitY8pkxEoo//BSMqNPXsBtIvGImwTIF7htlmD+Aeyyhuk
# DATA eEI5hwqLfxkRUn/Zf5bKH+/RVw7/nh3/tbiwvLycwH9furn4Ov7rPzf+q6Fh3jFRRzQhBA7S7ifiv+I74uwUvHyvP4VUXNLJgYXR
# DATA OF8MWBI1XmZPbLN/gh8p/uIRYZh98U8+PuxcZmTsoz+uU2Pxa9WbSuxWMpz3TKGuZHnBszjfB8CK/vSEDLhVC/LZjnEvhLsLYeVH
# DATA I3Cgh+hpuGd9JH3ayaPd1HqGhkORtLsWixrZyIqTb1aXllsKV7o7mgCCqoYBwiB07dFKad0MOASFr5qwNsWhlI7ppUwAUjMjDOMa
# DATA NOr31rd3Gh+GNr6TiexE9R4MRnuF8LrEdrU8k6VHiKfh8zRueAxYcqQdPC7bg2STqHTyLHCetLn3oP3VzcZaMiEz1JQJRavWLOmI
# DATA Se7ynqUzoHHn1DjgkXalkU726rlnQr2SthERksTcNWlmi3R1sqHZoLuJkXozipMr8OPOo6jstYcSXAcUBKB93mLeDj4U7AnyBLXQ
# DATA zg3bvzMkvC64aZ3mGaO+T1xqoNk3Fc4NMez/HUJIGVivSMEQCACVGRcRLGrmLbIJl8woFoolveKHsTRpemdzE+ArP0Si3rbdoqgO
# DATA GbfLt2UbgwyP0E6vjD7m2sV6tB+QDymZJY7QdMHcW4ahiPto9KTTlRQrk9YRG3YAwbM2giL6tuNchuzIfO7jbRxmeGq0nb5LbLBQ
# DATA o7SHOnTzMyGs07pj3fUkb2CbAuwlo3prRyWaNV0KSsaGC4unCf6FL3ujMwybRL8XG8YVy+aRYmCR8Q9FO0BhKCg5ptQbt2U4syeP
# DATA fae8D0HDTxeXSreXT0O/YyLUlJeFr25u7Kysb9QbgNlZ39jZtA8SRcjnsfFchw6QC7+YHlIjav2DmI/RY8J20wswn8LxMBi0P5rP
# DATA LOhT36tYkRlNnCek5DQZFYvyBjIri2sZ8RYpRhh9Op4jWMYTFgNe+jShhoZHxhEYhKrVZcZS5Irx8cIDGVVWILedIIZkXFJTVdcy
# DATA Yzgdu4ZHXyPVNMUcQM/mvHOPkucRuZapgPHQhybnHSM7MaZ4PM/54GzQw4SdFOAfFvPjUy+woN60HouE3zBlpkxxYpM9ONbJHCrZ
# DATA aDycGk8cNioLjXeUEo20SfaQ69gODzUlWtHrZE0zlTKORCrRVPtq4mhTkA6YZweATOKsoaeK1yjjOsBlTtujuCJzoYZDU0edhCDE
# DATA vCwseXemhWIWVmLelCkFX84UM9aUZoZ87+FxovziwsJCsZgNn5g9QZsfiCPEnyvZ5/2bIzdxMSfIOzG7pi0HtixXQw7TFQIBOoSd
# DATA ulIGVTE3M1lyLu2xT4aZm7tfv7eySrIlpTnffsXnX94jUGIosDkGA3VRTLWAFHgoKdnldGbXHKdVciYkQPDxeIyX5RmdSOspbYXU
# DATA HtqAtTN7et5w06LCojiIDGVNexIJsQ/uCtJzoyrdEaVPR7YHXjEp3Wu8AOW+NgOiID3w33FtUyZojPYCazeemVltac8TAw4hI1Nd
# DATA jghnpcBqm7ZGwoyWEgWHN2t4GTMMw3AkSkuLlgOBx0VlyilIa59IHeSkUhXboU7FZKIcTwF1pOVRRbnH1WUvKK/4cnKRi8lVX0rc
# DATA UPh97U5kCfPGRiGXOtPlaL1nYFilAT95pkhUlQNjwCZn/e0Npxd+eB4tCyT9h2Z1T+0BarnfM/G49K/FfJHqXh6fzzXuAhHpJgd1
# DATA FJN4WNj7M0XGhzl2NmWersy6cSRuG+e4aeS/ZVh+3s1kPppz3j6SNw+YU+Orw88orwDdJvyA2xe5SuhBaS3jpDDzcuHcO3NcLS55
# DATA rbjQlSLvdSLnVeLqrhGZl4MruGOc/36R4paoyWMu500k/y3EgxJiIknoKwfmv3B109rPTPwoWGma4A6ueVEvXlXiGKoyZ8iVp1cL
# DATA YVFS0yu7rFEtSD6LXJFMxdomQ2pJcNXdN6U1rZnKJfc5OCMsn0h3Lcw/miVeIDU9WL/XWNlZ39xob28+bKzWQyvQVjpPcfjRmCBu
# DATA NFMXa6vL0yN3vUxuP4Y0GwQLZRkt8XSDyrUenUvaZkF+mKD0N2o5uHbKBOB2UunfHqxvP1jZWX0vaUEE3Tq3L/gyEjcdMNIjjFaH
# DATA EGHzr777oGQsPbRRS0CyQAvynoiegGx9kW2jDrStTTMW1lEyoxu9ZKZGTxGEllAKwlXKI7TSrXbNpqcZq07Ky1jnMHDHUk3IOI4F
# DATA KrvOmbsBEreREbneqK+F6bileS5NLhJOnlnbrjfeX1e78E0UKOJAnP9o9ioTMpS0fNFpHkMcnJiCYG8yehyj8np8PI0rcwnJpukJ
# DATA rLru2zitRDpJn4Z1dmbqC5jwXYEg5aySWhjxQObMY4DmtpDJgQhoSySRVtNAPIyLph5JTmRbnXGvyfsJe8qClfxOkC3mBuBcAXNJ
# DATA SSUNV8SY5JqTM9b1/AfQPPrSMo8H7iumdc6iyJUHd9fvPdx8uE1LsrPSuFffCc+XI9AYu04UuCAD4RO8y8m1hYIDVRFiBGHVE0Go
# DATA PAG0FYkf4d3vVPnIHIMgLEQBbm94fLSn1BlosUY+EjAwGmOwQet3FKyIRAQfRxPAUYgRUwgRx3BTYpAdaIyU2Ro8jjDbthLJsQfc
# DATA dm6txJ+JMsKyBF6FNsLYVgm7otEYM/lc8WowQyYoW0XIqhJQe9odG6Vg1fYgX+bwQMP2bonlE/dv3FuwuNAjLgSd4o8xQwdbhjnR
# DATA WEkXAO8v3ekMcEpo0YQA5ewiLQn42d/fj1A9s76laz+CeFAA6ww62M9KsIEnhBDngI47Q8NdEXKERgBX6GUSjgzp7G+tfUls75mo
# DATA eIYGIr2BWeoDKZBatwvmInxGOkKH8SN6eNZUyaTooIuZPTReTeVhXMFT5fPIOgHl8OhsPl1rIhILk94l4+LSrvkzAamUDmC21uP0
# DATA agToN4MdwSfVgsAGIycfyVfl8sF59ShC1juJD/tjQKwdEtyRvGj1GH8yYVnynRbmrHrPDF3Ad3LkxPpKGg88Gd4hzKMD4cbt6Qip
# DATA xSCFnGYCvSkugDQ6l4LjqWw/bOypuNYflfzdn5I+LaF9jfy0jCejiWOrVH1545z2JbcqR87WiODpIKMpnoXFYhav8wqizDAldRch
# DATA u/AFvOuI8jyQ+7OA8fmhDbOTzGxmZpUgCqbHZvAqPSrQP5QdlXpl5kq2Q6by+BMDZA/yacgbRd6+pm/iJcQ9PQop5klHOMN11zyj
# DATA pCSSXMssFAD3HueivzDQJLWSsW1zWkEuZWrjRi8AQkAgM2wBp6uU6dTpWoakh3nycE1eehKX9ESaUinNwvPEFkpGwZNfreH6aly6
# DATA UvpAr/ga1mKYdI4ooUnW48s768iXXqKGs1nCuKGRIixiteF6uR4v9owh4SZeQtWa4eSZDvyAqXV1QX4MHiIy87E9ej5zvD2affLM
# DATA 9CfJ5UWiR1lSHQqPh51Hnf6gs0cYMGGaPvpKrpPpamrqFyZPpA6GHDsuHu2NRgPTP11dSTLqo+DqKo2zWRUXvJbjv4616m7qn7Kq
# DATA 1f4/qWR/6gFJVbfoTu+EEWsUyPKShFwBLAnOuYtHxNFI8LvRsN/FrNxcniC7DgHQMlHou6oKH4iWf7uce6vYfv727dDx7G9EaODV
# DATA vyc3TFFLGxNdGgjJBtZIvJ+xM6E2B0zFC42fMiSrnmQ/7H2f0Q0bWCSLHWssUInUkaleXVn7UPkI8alqKbBVtLvWWesAeC3cIQyD
# DATA Ca8dGY8kNxuMxHU6v756c6tO1hBbbZ1Pz67BKKwey96m9IjiqbMkEwClsIUTRyJp2Q0iRgC1J4ErsFGsQBz2KN4sLiwoQIzuaDCa
# DATA eKo17cQGyWX1VfWCsTQU+Ianj3LBpM6nmBS1krP5Ro1X3BS0JFeSVKWCLsxT2lD1TcWNhTR9oMGTq6vATdFoO4VQFEBX7E9FOVYH
# DATA AlIWmBCjMWh8MHOpVPbNkg/+ZDFgbehXjWHqQ3U1jSqeK5csPNPOwmYO0BZsr2/ck/CtqLlX+j6TFFndtYlxjGC56nUGYCRi8RNM
# DATA g4goievEYS1xJZBa3elhZ2roFWDpuUaMGQUqIJXEAajCUM8wfTwqS4LQGR2lraUjk+EgSVQY17LXO0Go5lRdAdyVVmUxElVEr9qE
# DATA wFYDEEzxWyjlVVoBa0gUyqYu5XZwoSEC0HETqQz3MfLzpwnLNrdou8qge5PspSec0PpNqwJo2zhik3mlFvuJNlrNvYSKq2HwdHdI
# DATA uxmz8/KcJO6T1ZsLiwu7w1Mz6/jRSFxKKbkSDbbJw2pRVx4J8j+y5g43JCjuOUGR6Stbwmx97MpLFQCwDJ+IoGMNUxMQcXnGyME3
# DATA CLOQJ8yuFcmd652Ppt15LDevCYRUdEAONMSimSJGUY3+DK4rNCx7CTX8MQYTC95Vk2mAoXG5Lprdqhrlkl8JkWlK4J0uhXMuoIF5
# DATA wI7R0SnlJGOQ7ZHfMpFZBDXEbUp3flp0smTxm9ZlBnMjdY6kN5TJuDzZu1M42Hsr2+21+lZ9Y62+sSP5mdTm5ICMTstQT7npjajB
# DATA sh/t2J+l/hxYxequeg4YYhduuKWjVHG59FJVDe1vnY9RyBF23BkweBcd5wBdKbj3SNw5xQXuDnssyVMyEDNk+qu/aWfwCFiCCI4g
# DATA UxkpV2K4BghG3hkGxiTiOayVxopPQK9beAPcV05TTSMPkbkOMOtQTSu1GinQQC3hcBSeH2FZow5lv5a//Gw45tQ3bUBmGxGOzt3U
# DATA kNx8asALxPaSw39n0KYOuBG5RreKZMFR35WHopNHSdWoAu1TQnx1eG9Wdfq++hSoomrG5vI+00G5UOK06Ns/p+wPBqCmPQvW+j8f
# DATA gTeVRHIj8mp2jLkEHaiTggGu5Mccc2B7U3ZHBilLWF9MGhqqDN5Rmx21XGBBtQ4qVoM8v3qdaZQgQm93fP5kJt/VeIxca8IYl1h0
# DATA rxY7Of18P76eOArPWQ+lr8LrA4aMJyvkkzsHxZvp1jzUX8xleGzUH2yKuztqFVY3N95dbzyoO+Ab9uauOq7jtN/tM9p+w1GC7vvl
# DATA IJ93OGarTCBltKytrORXadvkNJeZEBRuj9TLKH5LQ7h8yrkzD6KUPpJxPWdTRuc0ayim45Ma5SXLKWYmVnGmL+HPnLI1vLGyKmus
# DATA JbQApqVznwqFXDzpqAfF1LhartFDSsm+Q/ZakCWQsE0KN34Gg1BSyG15Zx30HlnEnDzI9VHFXqdpUK7GGVkyuJIJXEFgKQrgE7Xc
# DATA 8hyQ+mJW73tgXyFohxion5vPgoP17mWThZxnKmbsb1e+OEcr1jw69bj4xSmiiacJo9TxkC7aidgNuszY6AUcSJQweHkjqTJHySPl
# DATA fBNodXBs1Ok+V/5IjJmKrfMj92aGZJiovtmIvjCTLoqvGUqgqV5ZRECX2MvpdCqPfoNTVhNpvxRjrMq3bWikNDAOLRHnlMZtrylX
# DATA LlckekkEMNPnPymqF+12WNFkwt1Lr3dZjREH4EPYUZBXVhlTaaHlddM1lLJFmVHHaWtZYk6tFcpbnThmx1FJEAwWiBeervgOMy2+
# DATA oz4H8QS70jgQi2XQ2bSVOjnDPzkRU5vwyMnll1E878K6rtky2xbbXK3gjny7QsZ/B6Yrs+g2RH+HbigIOY4NH2k6sY4Y/sWaB3hG
# DATA EWEQfxX3fxwFfx3cvnXr5u3zeKPXN943ZCHtlAqeHH1QRA8Kk/CHnjDwWsEIDSi3buxWsr8X/4oSrmTp6yCWpPIggZikHDZrlsOm
# DATA uUyOg6Z9eFHGNKJrmQ9s9eH2Tnv74d3t1cb6FoYINeoPt+s8NlCHUNWCcewOlUXvcuEwZPd0QmDMeHaOS7Jkdrt4UUvF8lEyvfOf
# DATA rZkmh2qRltGfi85rV8mysTPEhAbSNC8wmRNt7U60VBgmejdgvChjuOhCokPt2NvX9fmj4NfLRVHnu2WmBMilzE0SkYM705QdaTW5
# DATA Ay0HgtLeCVYYVE4kjRkjEXfkjfoqb+S/fbiuI5z8GcFSuwSpiHMse8L1SbIccVxGk2mbOUWb2UKcjKslYi9dIlWea4tIlxMTym13
# DATA q5wmX04ytCavSMtIdKPs264rlJyPhzQR71NtuGQe4PVkymXPe7zUa5sfbAiyXau3797fXP1+fU3MluDTIGpireD9DYZP/OJYZfyZ
# DATA KfXvabkpUygmSRc6KZw8mtz3PEUzE9ARE9eFmY0V09OvncuPDWUJHjx529LjkjsU1U0jfxsfDxfJeJdWuy/vId3LeFBo/cuXxSmP
# DATA NepPyAKVvbtzbOJXYZO5uI3l3NacLJvMK0r59yacJJSvM47EKooPg5M7eGUxgmFkLEccQXQx/ToaDKC9gMzhlbk/e4uFzx5zdZaw
# DATA q7dtXdC2djWWMOv4v3LLTfLovX698DR0DTkS53nW6YQsMynU6AsDuBbMsgflTwV5ccvRBbTimXaeV54ky+vSNyuro+nSdz7ry/mt
# DATA OpcxNuRWuSdT1mUoj5MBAUn1t2XtsX/LMh9x5coshPXkfz3N1HWuCU8xkBlg6Jcw/VzMCCLT8HErTr7gzKR2V2HduGjCu9eWkQzL
# DATA yDedDTCV0ZnJAImujie2fswR9HXkWgoGJZVKRZ/h4AHp2+Dq2Apuc0UdPWc4Tfs038kbCUIZKA0fOXTWyKVi9OSkFkpYjnA27kZO
# DATA sA1GVfAhKsxd1Z0x19RzQJ+lhrdBUHLEzAIjtueh0hl2D0eT2S6Ia+uN+irgL6AHRP3B1s6HOgqwL4Pbz6GJt2wKSqqTgAjGYITI
# DATA j/BmRQNSFNu5RJ9R0w8upyrCQ5GO8iDNF8jR2PyBUSmRpBGcLSNt/WGvdl9q2idbjtStL22gmw9W1hOKNrS65scfJT1wfzCle9IA
# DATA In9rooIKoyHLiyevIurk5YrKKFW0BxlLxLCZyVsYeUljdwbxVfcic+UkdoBYub8R1NGu/2B9e2c7TGxFUt0wq0lXvRD7s/Qu/X1r
# DATA +EkqN/1VV3REyCRinhh0Jt3D/qOIb7ZcFzqNBqNhN7ojs7sb6rQ3g+Mhhv1HusU+5DzpDDmKIAJTAKU92ZvAttcuqtxemkpGdeyc
# DATA DsJG1bl0NAm2kB3i7zwBtmcCH3iquSgulIuzgOeEnLR5eYU/tlyZdPnsoZcITKo9+siYCf1y91C8WMD3ihkI1lYiMlGEjw7R1/Gg
# DATA 0428INW1w+l0XJ3XMOXVmwsUqOUrDMsst0FlokFufTqkpH21ZPbbglN5akefGrF1VfALEjQfl8GrcBxRaKEQU1F9Ug2aljODaqro
# DATA KN7DMaLaiPL74eLS25UF8X+L1afw9BQDPFxNPTEdeOOpA3VA4lZ5MhqkOUe4NY0ODigs92nYm/Qx1y+Z2MpSBzQaS/3h0/Co86QM
# DATA hmMotLhwRDrIJ2Ueb3gzPHUboIjJ7mHU/QhrmIq5g6GGqw/WULoUVIc8Ff+7HwEOwDVedz0ZMAvzaCoUsvI81XmtWBHcZ1iY1P5a
# DATA BktjvtFJZfTROwvVxWKx0kVYgULRKSF+4rh/UaGQaKDrt5DJc1iufiB4G3Ap8WBxiUIpJ9P2OJr0R+AHFi4txGLIaYcrzHhTLpa4
# DATA xs2EpYCrHX207atPZYh2wgWGliW5zhTbrbvGx4HbN34sXf0ZQEDlpbbUJmQ9td54qt4QvThVb0GXIPcLLJb2luMhcAW6a65skaas
# DATA tTaSjgqSYvbFoqaKiQEa5mEZN2UxAXpYXRLSybg/jMIc/ECyFZyYe5tr9bsP70HhIzFzfbiyTbvj2kKIEyhZQfjtheq3kdctL9+s
# DATA iv8ZH+ePe2MkYBnK5WM1eobQmanqC6mqTkZKnCxD/GZ1Hv6rn9GkVOdZBWy5XdN0yS7QJOmaJEWY9eCz01nsmOSospSjxD3B1ey/
# DATA Gr8xh3HZjrFVRAEpJInEQRdw3deT6+IZXtHCWqAPp5fAl0l1ZTOVaZl60FSVfw7laW+2MkHey2y1plcHldscduqG5BAkpo2FxjDF
# DATA mBS8yof8JEY0HJmNtrIyOTiG3bqFvxQkZhvoCtptsXrtdtF4syLou93hVwqhCs0GmiW44FozVKr0ssYvJnQR9EsPCYNmyvcdVmJo
# DATA 08vxJFIsuXw8GfAvfBEoA6I2Hl4gUaljWzkC4i1F0AvjHuAlsszRlsi8juOoDHxHf6OaSCxyg/XlKegDG2hlzEy5DOQrSkP4aG0L
# DATA tV/Sc8MQLE3vcNvzJURhHiHvUjPFWlNkz4cesRxr/8jOn0lVPcE62aBCgyPbiYlS4B8gSKDaZxYS16M1H8viP1A61lBJmNreRgHw
# DATA UooLj4DuVr3jo3Fc8CJjY72k3MCPBhA3fjf5ZDSMBXm1O3G332dsZBbjB1k9jEJL54v2dixM+jWxAujDpJ+TRylG/V7SPceESzXt
# DATA V7XA6UHJVnSBEyEqrdz+FNVaqFcd452eeolwPmuK+aqAn5Vxjl5K9fbzDGrGWuC2zqAOiVylenuRBXd5RkZ7LuqwO0uGqo3mm/Ui
# DATA F+iVwbYyOmQA3bp9gYcXb1hzSBN5w+86nXMW+JtBmJn9kNzdHb1UW5+vVWPToP7V7YrhhKu0WMZEgrIjxKuqh/5ZPocioW6cAvQN
# DATA jXj2cOWhaKT8ZV1/YmHR27CXdyNmN6sP4Koj+oLVIrvp8zOiWV2xTvwE+rvy4k3pVjF9nzz9KDphByIMxrJCxryHbfH0AntHH89J
# DATA xJ+ESSI5CjWd0jrRXGhlN2iIAGnXSoPcpcP3VayWFr/coWo4nrR1kjWbRnIJDZVNchosSoi6omNttBi129ildhv2YbvNPYI1jvsH
# DATA w2NEBCzAx86gsr1+b6feeFAK9Pf3Hm6ZGdLpOf1ToApKAecQud4WN7ETrWZJur6Q7D13Yb9PEhe2TyA/fR1a0V6coFwZPYrGk2i/
# DATA /yTD9dPGmLXyyyo0vlwZHT3dE1fhGFN5uzDF6VKN6NHZvwZnf3z5k7PPzn539pX47+fBy49ffiIePBdfX7z872efBfD85Sei2NnX
# DATA Z789++Lsy5e/fPkPoij8/s/B2Rfwy3N8+cuzF5Xg7H+LMs9FdS9efgJvPz/7LdT/8mOrXAD/Dw2/OPv07Lko+dXLn0Pjfy+KfH72
# DATA ZbCytV4WT78WdUFLz+9Av3768p+gIvH8U/H5l+Lbc9EDp8PPscOi/rPfn/0BX8YKKu4tm9S3K6ur9e3t9rsr6/d5Qn4l6vpadOoz
# DATA 8e8XUFuucXOjf8SXPxflqdHArO7lL3BG3tvZ2dou63kpBaL41ziKn4oqv+LPvxDP6bWPRYO/9M/ec5i9wJwoZzpe/lwO4I/i68ei
# DATA FCzRv4mJo2LQ2S9U9605e/nzxJxhxEn7XTFX7QcQlHIXbEXr76/s1HHq/k/K4uEARb9/B1/lsn8FMyAeAuU9h/GSgQUHB53AR8Yg
# DATA F24vLIiu/y9ZrZxx/P5cdFyMONFhaYvUHceOOiT69dmvX/5crC3R4HnIMsDu4aThZP6Be/VrHO9n4uPi7eD7/bupHdNpMT39Sts6
# DATA vxYffg/9/Kko96KEv2LzXwJhvpDfn/M0IgFWA1Btx9V5djeMnnSOxgN0BEx0DimUu2Yxi/9BLYheCVL9DRCP3TNs7DMxmz/Fhj8W
# DATA hbEusW786pe8XF++/AVQulsB0ugfcSS/OPu9qOZznInO8XRk9vI0nSlLNojeU5pDC/nh7N9FzbBMzwWXeJFgHJ6dwov5e6RA2In/
# DATA mLGtxcd/Cc5+J9bkJ0jbX+JKfCFKfSXI58XZb/AXavuXwM5EXV/g8koqE1zt56JK0QX4VfwmiPKTChwa3/oL/psOhChx8mrbWBB/
# DATA t5eX8V/x5/y7tLS8eFs+4+dvLy7d/law8E1MwDFosEST3/r/8+/atWur0WRKobhRwG4+IMxyXlFtPiYVXfQ4aEhblnSVokADDNrt
# DATA H+G1UCpV5XeqiFRi8hlcQ+TnUTyHkThgFBn09wJ+DDK6LDJRlWnJTD05UR8FJxqDmD5HFbKQKSukK2nJMg216WFcCvBiwLpiIVEP
# DATA 43hQuA7ydQlBLjksc7/TH8D1h3ldLRQH+mfAagTL+AmyFclStupCngYGJljXi5d/z0wLOB6zHBZr4MxF/vs1FBQHDEk+lij0AnmW
# DATA aOITqEqU+gJPyOehi0xuyK1i8IVmyCMBTz4YCyTyg9RYNRiSuPN0xlMYzeh4Cg/JZqdQjW8ZjiOII03q9e6ol5VFzJkhD5JyhTCO
# DATA pDugpsD2uNOfFA5H8ZThHPRPJUoeYy5dXAuVRx35L8k32Wwh3gbvrv4jirHBO59RZZG1HqJiAzEdr0XWq3aMNbiBdREvTxxwYwKu
# DATA wu/h7nB3srsQztR0ktyP8gMQCZ90UkwTJ3OAMhHIYCCVshQmjnAUu1+8/BkQA8hpn+IrgkqSeYbHBpIAjCoZAr64sLQcXMd/Znb4
# DATA P5K0xycsU7DqPJzksvNibGUpvaFA9MKU0MTR/Y8gowUP+ndVqreGuHijL1EQj1x2BEsf/d0xOJiAezU4oR7HjFkqUWzBhAA0VFEE
# DATA 0CZCF2uMn8APUjylG/7eCejNi2qhracUDsJ8IHxya+E7aNMajsBTAD6hd0M0RMvEt28vo4sKMgrVrBzVpqhle/u+jNeIgx5mLEJM
# DATA y36MMengbTNl3PQ7YpuAtkUs5PDH0WQkUe0pPIPL045VCYv2wt4oiim+3dw2oXQlnDkS2Dvim9589liy0UV8f0lO6SUjELx+C2wR
# DATA qMgRcX8DewFoiy5Gz7OdH6+ifsUHYB5wl3vOioLFhfScoUnB+k2Gvdpmk6tcq8uv0znWyr5KwnUCBGW6rsGN8VM4pYwZFdxAPHmO
# DATA N4nnCRE/B6f8RnrBCYVIlogHRAIgPoBdzZIf+DsdkT+WdqI3A1gnGYYfB3uj6WHQ2F7BDVtfXdteuSMOKE6RcgROdvjr0ah3POgj
# DATA ZorBrsbHe4N+FxBtE0QgfhJszKIHH79hZuapaSxfFz9Jehp3INUFWVHjuCrrlPxSu+wanXuj5jSSuSt/lbjS63MDjgOxDF8L2ecT
# DATA FHY+kSom1Hv5hJ6XP5WejGD19E6U3i1ooO6Rsd2Zq0ovAkGmkEhlI+qqYDFY5PZ01I5FwWEvLmCDMjlUjZJDLbYg9aAkjMpw9Lgg
# DATA aaNyPO0WK/BN9OJoXJjBu1De+yJA9dXnNAt8U/YJfnDl/Se49H5FWsLnL/8Bb/bi2m9nwfGcgSoMY3wyW+AyDEhpspc+Vi8mxvFy
# DATA RmARkhgSTljEfAh1xAoPxyicG8Hn7H/S1KHI9BvsVOzIXshRlOxlCFlKYyIm+GNBw1+icuHzMNF1j1etz4/WeCHhSQtzBnRdCCFH
# DATA UvdQnDiVcXREZpj+I0jYCF9ZQBn0dD4i04sCazGMEJSHULY6Dz9b0BvnylN79n9RZ/QZHq6fWYIeCIC2PGuKhO6citf/gJcbNaso
# DATA JxryrBigRMgeW/IZ9ToZd+uxPtj4cCBAign6sdjzOEnEGZwxd6ajo36X23InTtVjmRTYipC/WTE0N3Aza5UMxDqsK06JOxvLUDDO
# DATA YmSTXnowZmLYY2ecbhyXXRhde2R5mQxHJr4kVDlIisMXdLFPQG04hj1ew/g1cj5HGNr9/pNaWJkO4nLoWU2Eyx3Flf0ecP6C2Uj4
# DATA eC9E+4xg6VHnyM2aBM/Y/pcYmFFif3AcHzqBdNBefDLsFmQZMYbhqGDEQ49i5dVOi45h4rQvIdZvYAwBuRtKjKlrxTxawabFhaNo
# DATA ejjqlRhJwEFgM1NUUwErPktmojZuhPAkeSm8ffPby56fgZ8F/yVYGC28/XYWj13b2Db7XBW8QBzlv1M2A+PqB9x0fWNdMY4AVe3S
# DATA 5IBs4ba4UzmYU6YqqUJYJeyxpyGlJIaW+SqxDjjphweFsNkbxq3dYXgDh2k4Ocj1igaYkRiSICjvT/GOcnWLJkf9KQWvF57CL+3u
# DATA YHTc2x90wDI+7pPxOMSQe1o3MuarQpzwhd496I7oNX5LLV3KqzIFAPWTEg64nYiOOMmNp3MgBhqJCMzRGNUqechoCSQ/VdpItvwI
# DATA vTrEjAKL4y8T/qLyN1AlFUrYPiMc6uxfgTiU/ZOoSBwXL39GAvyXaC/F8+fXbEf4ii90ggbLSn32nAyCUCR0kMFMuDc5Vga4yS1S
# DATA /BuS9GdnvxeNgeHnY23H+ikeeMZmsNpndneRIByL7VJtEORa+dGoPyzsh08/OgUz9CPwcyePjpI1/TK7QwVh9TD3KvMa8Nk2pDak
# DATA oFIg2U4OQdCnhLOpGIxJtg8htmKEUBqJISehAQ1YubFbbt34nn5SMcEDW0+XSpA4EmubLb6kqWxp02iefig4A7oJhxxiQL0Nb+C/
# DATA N0KMJkCqlwMx04Tiag9ijQ5pn7m68kRx+XH+UWcyP+jv6VSw8+LxvCUXphUyZEWZJ0ZxUWr6hlypGxhCEd4Qr90Ik5EUdiCWkXfG
# DATA 1XYYYxM1x6SOzq89cVytghs1ZCk3gIsRdWO1xbzdLc9MnGP4Apl3DTPMRHqX0x6B29xEpnoRGwFr1ynaPCSs82h0ukdRuUnE22oq
# DATA xEsA2+EKZ/Mah2gF10HPgT/APfETZHZ/sJgd94nEAupsMkJba7SxRKZG+xybSfFANOL+Fq+oL4KV1Qd1pe6N0XYsDrNx1BUXREhk
# DATA jzqTJ1F3G5Oa/N3xCNwEA9CZ9NBlsDsl3Ux8GA0G8nfSnwhBsDOmUwwHoqMMd3eBhnbFX2jEHl6jh9fMZ2/Bs7fe4h4a9EHJibjD
# DATA /G9YnJe0cCOUYXh2gsyw+XDYnwpZY80IKGhEtiFt5/62eUfeHa7sC1mmxjFT5RGIiBE7qgUccMyt7Q4/6MBp4S2LvMnqDEe2iP7s
# DATA gD++EJLiw5Eo9/BBJ/6otiCku92hmv3aNcHoaE5vhNd2QUnEB9Xt5eULTBBunlzTIyfGmBSxr8SkdQYwpuYO1CTe2hyudoQc3utM
# DATA atfL4v+ChZulxVvVhYUq8Clr6A1BWOLc/HHUW4sGnZPtqFu7eRtKbYFSPobLQG0qzlisf50smy2a3ah396SGnY/VxDpz4YkwuVBw
# DATA Sa64EonGQAEhY1TpmXKGggrAMAZACCH13vRQRTtOpCRruHw2jYgIUystvrLe0HIJpVMd40Eo05cVbREz2J4KvoKPOGgz18E4GUxx
# DATA Q1njkj9KmZbDD2sys26ypMX5jyc4Ke5boLQa+yM0HK9ONeGGN7Cr7epUpHW5U7H0XZ0Karw6diw09Ml0JU14/Y5PLN9jqaqb3Yzp
# DATA 8X2+Ng0SMpo2bqCdihQGRc18C+1UTBHaX7ET4EmCpjkSFjXN+i88DCLvqpWYFeZNHdriI52EPn9bhmM0oI3JU7hCwITJu2IKyfC+
# DATA syXRN4PvR9EYLZUSASiQRzHeuCGn87A7OAa06wA8M/ZG0zAOBhDPzxeSuJLMkt0MpwMZi8nbsmpMprWbKWaSB2UawytaKCjylrfK
# DATA wr40y9jpEukg4GmyYBz9yiYSdI0kvNNB7MnnzfIL+CkR5JkxEpRdrF+hzz6UJK/MQuaFr1/+jK6PL/+FHDPwgonGebhgipPZSQFD
# DATA 3tyiyabVmVbxjvkT9KSVwxt7hpO030sZju6Ew7KlGLmQEzNY339EkB+YwJNVZCSSiZcf9eG6YvADnXJOYnhEwWB0UHE838Ozfzcc
# DATA W8SMVsUFynAPRFA7nXsychOjs243NF1i2O8PXWzWN9ZL2qFC/D+b2yHwFQZSM1JppfsuLv5le/qluL/tP24fHHcmvVfoBZjt/7e4
# DATA dOv2ku3/t7hwc3Hhtf/fN+T/txOBbbsz6Q8AMiEGQwvkjWQkn4fvfiCkWMymysdRifTv/SElHQVLxIQSDJ9kuQDud4fTwTn8/eLD
# DATA 42lfvUBhJ+fzAOTvgP4jFVzosEOBUjP85sjtz+8dJw5/x1Fu+Va210U0fFR7ev36KK5wgKA4X++vtlfuo+f5qqHwneln1yCPRuMc
# DATA Ax+x35JV8+XHcNvWgQQvpM0NoxrEf/8ZHopXxLLeCTz8dF8IXY8B6ensU/CRQbf8n778ZTjTh0/MWds4DmU+CAnid9hHM6UxyVto
# DATA u7HwqWysXLZew5uVxx3BoOVk31peyANJSW9OQVk9hB4V0yH5PY0sLiSA6o3O71Cp+pOxjfemK/uoPxi4UIy6lSxzmm1Io1umVjBJ
# DATA O06qdjpJH9n6aTDFovX1E9ShAzl8qeJsBJloC/clLHnimPFa8sCoRuZvs34ccT5r31+WsW8S7Y1G07ZkpwUxbSVWkXWn4nokNpmQ
# DATA aEaQ/r3GKpeE6rcMcy1rAAnoeNif1lIVNIkXEWFVq7I05VG7V0J7X1h+GDkpkNvP5V5x1Jl8hJp1eonAUwhzImTN4w7izYnpLqOD
# DATA 149Ge2KDi0EDut149Fi8NBjFMUzfoP9RJBWV4i42nXSGcR+OPbxYuppHMYuXVzsyJ4ClK6WpyHChcBM6p7fohpg1qUOE/ihVoZWz
# DATA HTI99PqUlXN6WEc/ippMkEEzWKS0RrvDVL2hXaOpOQRYNp4VUcm1gHOmirOwszeIDC3j1iie1uaP48n8Xn84PzkKyvtBohtWM2kq
# DATA OgRWKh/DBchQ0xnaSvSINzZUSCm0BdnDVV+qxBKlqMsh7aUK5rm21ol6CYkXUGiSrUp/Hj7KKFa2ysQ5gxWgUB715AFZCij2V3SN
# DATA wxAiMX3iHs7fHh/2u4c1kpkq+KUkpTIzcZR4nbD5MPsQSUN8lGJt4kf5CWAM7TOdkHb3H4tC2EIhFF9sM4N4kDjBuUL7qGeH5hrN
# DATA NfI5CTjTSvrj4Q8VdOWL4TigVB7HMeSVpim3LBQZ7XI/M2r01Ofjbf/hE6nY8elrDur9LftICZ52R0rPRlTbHymk9uwrnkNpC1HT
# DATA yw/KYo6sIoIo3ULikb0SsjLWkKhSM4bFgYIO15aO0p/isEi0VA/BcdONz6W5UI4fyYH0+nFnctQG/gseFEyqSHT2GVj0HYIM+iw2
# DATA Y4CaNs/R50X/ZNa/IniMrF+mEgPZAnRuoMKQQnAlWAlAjhMcTOKMTgC3FP14QVUxCPrsgG+wjJ4LGtsdDQaMU1Qu42mMfSPeXi4L
# DATA 9kM0V0NkRc3oxG94wkBijrGgnpPaSrd7POl00XaxCNoy2jg6G7XkVK2iN/mE3GnGC7AQxhuz9k9CtjE0mthZce87EvP1+DAaMlw7
# DATA B491+gNDc+nvjN1706SawSVy7uI0ktfbFt3C2Qv5J2LzvoAo0k9t2j777E5A/kno0/y5tMCmijDID/gH+fBrqALMpOAUjR6QFpyr
# DATA 2hmFoj1f5pHEEFy4BwDoTdl0XjnUWU5AL++7TEsh3CHEBbumetSoA1D0Wr2RC0OLq6EhxRX+2lysthSkk3xWXWyB2hVw6sMW6RHN
# DATA 302WKWtllknBYlzNQssxm88SfbXT2/OzX6ODO1BR0jL+hdLyFxNufOG8WHZHQAcfgspg1P0ocS8DR3hEAhnyDVJ822yvNuorO8Ez
# DATA +tJY+6AhP29svrt5//7mB5akQvj3QmycHI8BUUbCfOxP4PbiOLYi2ryDIbK+sWNCiGRDiiRhRSSQvn6jvX5vw1Xafj862RsJ8Whd
# DATA 9rRQzEY2OVev/EAnxqyw4Xv2tRSWyZgzUICJ26Z4WID/lPgJ4JO06z/I0EwnZEGN63V5C0NiMjMwV0IlxKCAI/6H4ax30vnf1wgq
# DATA 8PJnGHFDvNKvjQpts4e5nQzDx/nsGRmYMX6Tg9mqMjqYtgsM5v0nVKv9PFWH5hmglCjCPzUbA6V6KXcOwBXxFZkAMvX/iwu3bi/f
# DATA dPX/by+8jv//Rv7efENdvCED9fhkejga3py7du3afU7dDbl0iEqkk1oF9gmn+qY03pgjAFHVIDPAZHR8cIgSoZKacxsGDjsxGATU
# DATA 16NOlywFgJ+Cegw4cuhH0PsCwEkDYoLj6XuCNQ6uAl5AiJDqM7haTanZdOMD8AzL2oCNHU8Goq3KhHon2+TOluBnODjmVAeI9xit
# DATA aIcHhPj1/sKo4XOUnRoN6myvb6Orv5DkjCwDc6v31+HGhGuOudlJ5SIljHBudXNjRwhi9QZAVu00Nu9jcVsMAWXqZDQI57brjffX
# DATA V+v2HYyx3pBilBpx7uHG+k67sbm5o2Ubn7PY3NbDBiTBgFSeKXWWHy2KlndW7tW3MUQKtRicH6U3ejxERQ5GSlGaRkZzpbwRISfH
# DATA POEXwJmjPxRLydiv/X35S1eQ81C8UJx7sPKD9v3Ne+27H+5gk0bYvFLbUhKmyehAzHXM+WUmcqUFQQEUIeLBl4LokQ6PEbtiC8In
# DATA 48NgD0xsYh+JeRhTmbjE+TGkXCrF6BivyZ3HAZOhjASHPUb3N6K4Gig1233ImYgPWBlFV247RYWViRQ9XGD7KOBpXvF5VpsYCflY
# DATA O8MuHKI9mcVadkLqH3ShNIWNUd9BJAOheaEhiz3MiU6Lw1moaNUJjh2umFEvqbl5iHSTzI9zr1Hf3rbFbmfAlGVEriuqFOS4nKyV
# DATA wxGoxTACFP5T8Ny/ZTXWDGurAUs+ACC+MZq+C+TgRJMZFTwNcZbQP4dyU+C/qE6NeisAlS16BDdqpCQAJEescYZyiQ1EdrFPHvVH
# DATA qIuTDTS59pZCL4CXBLMQWyrCRC7AgwShxlIbAvh75NUkCBbMh9oXCjbeYyFfxgqpgNa0AgbkJwVsCSJoraeyU8Xk6JvGKFpNWRBc
# DATA n446TwoLJVyKsjsWPTOtYqLKCnEW6kuNZ9R+rSZq5VTwsI1xDcEpDUIUdp8sLJR3nyzu7z55e198+M5+i5OOYdmiuIMuLbTm7EHw
# DATA wkC/C56nN4Lm07Cj1xFrAjR6YiJUUHzHf09bxWZ5abnqtsF5/GDQohlR0Zwv9x1mBeR3fD6tVIvL3ci/q+ownCQvsB3jsVxCU+tP
# DATA lurdL7M3qMPzjI1q3zDUncL0sJLeVMX0Pvp3OpKteO5QsbOflPZiPIg42kpP2PgQ0cbZ+5OLhDzBcMpTimvVEZv1JrlqwsoNoP3g
# DATA G57J4vmQFUMTzcVu7lXUEcjtB4c0V2ltStd/DyBPiakLzq3fxtu6fEzz1sR5q7a8iQ71FKA7SoG3e3x8VFCVNrHCVmbdgjkUZvKI
# DATA YjJZJzpnqE7UgoWq1+XDXSvOpTVAkyJYXpTPXK8fjwedk6CDEXUdSHEQXFsIGGzgWsX1P8gmWcMrMJEMVoiqBinrwyNBoPIgWYe5
# DATA gsxHSNY3gkX5w6qYeuA7g2hYoHn1JcJA0t2eYmIKqyynfmPyxws2NuEmRoomXeJviwsLnneIAKhz17HMvNmK26XYOBaNLaMfUxYL
# DATA ySyrfhbqVBoNOuMYMoXgaomXLKosGO3sC3KID6khkoceAxF6e4LHVzExAogIP4KONCR1Ge3KR+ZxnzxSTgU77w4EKVjykOFkKZXF
# DATA gliI8UuEj8HogJk+ezrwmQtZRyHZjyenpeQqmDkimVUxb3Tl+hAd7xWCl6hO15Ijndn5EpixDGhmbVHh9/s9v3r1g8bmxv0PpU7V
# DATA UrbWf7B6P1PZmkAoUKIY8Mlknsmqy1hVeQjKhc7DLcGKPnOXSi9eheCKZNilemyl6CS/X/0LBY97AAdkGSsFbRoqgpiR7gCSAO/3
# DATA XD8og0tp1ep+j+P6k3TZRuou0AWI71YQ5zHVQaB8OSJppxA2QUagzHTTyT6e4OFbH5bfOiq/1dt5673qWw+qb23/15Bc+yoHR3TG
# DATA oxjRQq8EuodA0in4Rk2Rl0SoImrD4+l++dsQjQojj2shu3lIGYT7JD2PksNiNCamtMjYnzbR5KLKla2t+saaS4qpDlZqukGjSj2t
# DATA ug7wKfMfMpIz2YYkPLdSTkM6KuXZQT8W89YsbuAQJgmIe3BlyqYwg4lR5jaJbpVgZXJbpE4xTk4qJ2QG+M3OFG8Q+Mnis8yvsqfG
# DATA FGdphqTSxBgdurtpi88VcXbrHg4alYcbK++LaVi5e78eprJg2Zfk0swyfTXWzF0g6V5/30Bo+HyOhhMJK4JBT/YqHwkewBBI6DcI
# DATA mBlUzuM36DihVLbb69uN+r2CrERibaRGseSYRX0DOB52O3TRMOtnqA9LsWUb5aj3cRR9JAWaxPtl+31niKCeqsl64LZRsEt7aDTV
# DATA gJM9YgoGxhcVhoMct1kT9Ef8F4zJU3R6K+whz24u0YVFlWhWodhESG09LgICMBUC12+uh8HD0ll9Rm+iYY9vMjDJkK+1MAnL8AeM
# DATA GhANgtZ1xnYPvl//EH8KyfNcz/NedNAfDlMqulu/t76RuypAL6A+wZGPgB66dlC+4Y/kaSHkgu/qX+Uzh155osJmo762srpTXwuM
# DATA PrTwDBYlmlwvYDsVWX0hrj+CR8Ua08ra8/yrBIRK3mMtgxbdXpuUDkRev8+rAFDXJzN7cS14Kluk3JclxRk5s6n86slYx2IOJfMz
# DATA eKp8JC/9oFWGpjAFofyxcjAY7RXC61Kp0azeXgZ9ERZSpbwtx0JCSbx9c0lDh1GTIH5y4xnaBARxsVUJ+E6C1RlmVnyHrjyGGI/H
# DATA uoffGfMNbiRk1sAqmsbrrWLxyi/K+1ZuekMa70dZU+I9kHwphy90PF3miEo7dVLPq4xjiPE5pv3hcTTnCXQxkkCn8/+c7NO8HRFa
# DATA KtJmBZgz3IsEt/vhbny98E41egLGsd34RvGdAkPCtFsGekzrelEUrEHhyvXiX9l5n8FYU3lQrPp1PpqzEvd5BnTyWJD6M+Qrz1jK
# DATA e6YDI58BxtI7H0Unz+DIBCUZxCw/izuD6bNejNABMJjmYgtbXk+ZZbnFqPBSy/B4wyTXu9d2w7DofVV0HBQiWEMx+OtasFxNDVBy
# DATA eCq94+6phCCZ2DBUDaKIjECbUXhK/Uf0J/wEPzF39/AFYgN4ADldP0XMyNoA8tsz0gvd6I29SOcN/KN86qmtknEItWQMCh/jUoVf
# DATA eKd/VCx0jqeHYov/GFWJglCa1VqLiGtPEEA0eSYWst8tAo3tbgMmzSTcXTTqNg9Vt4WQ2xCVNa8JnvXO7p5FnOL5dn21Ud95trWy
# DATA vf3BZmPtGWZNecbHZvsdcW4+EwXW6hs76yv3n61srdOzlYc772021v/rCmQXKrqVcmNqMMXmD3cnu8PWjTA83wBmCxXN3Xh3u3X9
# DATA HdHqLFHm2V8Vw1KqcJDVjd296ORvjEGaEFBp3/dCmway6i8ALI94vcX/ijpuVMqt69X5eZi6eP571daNKn1q3fheYg6/l937J4t7
# DATA u83mQvmd1vVmUJ4X//1e+b9Ja1HiPQnp1T3sTDpdCLBGYB71TewnLAkKUvMhxEdMQ5DbBJPSb+NmurkUkI+j9cMbtWBx6e0skVUJ
# DATA dGt8XQw49WVMUd+deEpI7pVg5zBSCltLdUeaSvAcIax2dKuoAAwfy4O2llre/MRVWH6kBLhT0g3DGwA5IjsLj+TnU77cDgCxd9pW
# DATA jiht9lMpaAt8g4zgwdHxFLyPg/v4CmLQl6CfQ8GOpthh8J4gJwHxtTMl4Plg2jkwTO/jUdznq7KO9iSRp1F/sLGyCpmbGvWtze31
# DATA nc3Gh5Redzo96gznFepNWXXXtZ+lYqMJOp93vgNtqu7kM4o36vfrK9t1Fe0pzXrstFLQiqdQ5jMSJ13lQEglx3vgUjuPLc4/1Q2f
# DATA zkvPoHlai3eUW0cbXTdqT10v/VPDCZ5wyuLa03ClC+cQqEXAgQMCUgAf9dGwx83fQIm2BAnQRb3lVTYQVkEgL3fhWeiJ0Q0fCios
# DATA rxxwemm9BOY9IjylNw3HT/beKSgnDyNlBghhkygej4ZxlLiB8nOSiZZu3WZPErhiqrWG408UB6u4LnGhBcSZt9FMoGKTqIxjWKWo
# DATA BdTLi1CM2Ao4RqyGUT06B6jU0pRccFoVJfjoZ18Rh8wf7fYET5f/AT7ZOXCiNSd2m71JZx9sLf0Y68MMlYlCY3GiywzPVsmLDJzz
# DATA OsBYwAvdCvviZ8yQZEkSb6opK2EKRP5ZsSZFHLn4b/EdMT1mzTMG8X69sS2kBqV8m+C9e3osWHfhqDMGRFWuT4KeQ0IsjZI0PCnA
# DATA S0Cni8tvL3/75u3lt8mSAU/FSYRVXqQvPHfUpRtBYaFUFPugsByUcXdQvTps1nKnqWZabPzXLq9PN2rCJymAwqzx4wBh3M6AnXvL
# DATA 2sWIKy1RdXNNw/YO5PNjqmL539i9FiK/n2jyb16zLZ5wrIOnlT0pzkWpoJRGfv7w4foav4riBX7MubP+9mF9eye9X7F4NDbdUNoy
# DATA Yv5InDryG+eKVVDA1Rneb+wA4XECmzNwt8V320Qmxpyle8qvEH+4sb3ybr29tbLzXmj1KJ9dUxZOWDWTXn16zhQl6ckyoFnpGWqP
# DATA XTQsXT4dEMsgElVVCdVUriXTaEh9bi60HKUfBYuiWc7Msq3eKBJfX9naatNVCsVqH8YXeDrXAhoJw2eZ+iSlqLHGZoRQgB7CVrn+
# DATA ULdagyvEPiB8Pr29fCo1DaxhSA5JKgIQJpfyABkAssxGqDToXW8uZRLRg/Xt7fWNe3IC+FQGLQVgvh51upVh9JirU/C/pYC9bkvS
# DATA /boSH3aE5IHSWK9/AKJf0eM7lk73JSG+k9K1Ss2fOijesiKgqYK5cYuJPAa8QobUF5sIguxirJDBmxJwENwDMVRbrxw4ryDqGDuy
# DATA C07CmICF8NFocHwUgSNw03IRVN6RTXydVFH4CZI3UY39fa9ypWBsASzJzJnyOMEDKSMhaCK6fiUcsIHF5K1dKVCSbtyys/Igr4ZF
# DATA IZUstYotQ9OjtqFYvZMxXLzCvf7QhHgkQDhmNkUN+FhNNsnu1W2IExC/A6s6nfN5L5heBnBUNGVHWr7oTYveuan2g82HGzvQ8Lv3
# DATA 11d3PMnQuHrHcIerJ/VeslUfpdtHi0QENhqQU4J6d9NLWuWnSMtDnvIi7CD26auSXAo+7egiKFal30M4AnayrKI597x5n3jpOO+2
# DATA rCQIURPLX0+TgK8AuBv12nyQGrnkpT26mIpqwQHbhRmYr6AkEFd8IGxI+RsUiL+g3kC6dUp0CxcL1wGkSALexn1QTJgYtyoAhoNf
# DATA gvJdNL0bQ6PoCt+40BGEImLxJXN24CfUcSQ6BeAd0PRoWGbPhN0hP0NYWhuONz/WhY90deTFfMABGyUOPneXNpE6UmMLJKEySoQf
# DATA YYgg2a8rDI2wXB6OHosP3Jtz1zShmUqtQV4KECBFSLCgk5+esMBoSC6GBggAcAHzbAAc60TlPRW8EA+1O5LuIKaz0wumgB1Dx2rU
# DATA EUc2TrfSAaWKmCrxQPrBmZGGwBI1pWx6KQFTYmtSWx5GpeMytPRogr1mCmbyGc+4OAciU27MEte4YzeXgu/WbAGoFiwvfOe2wiw/
# DATA 1DYF1o0SjvHuBCF2UB8E7vlhq/gnJDfJlA1JGUn5aKJGqqpistvtvtix7bbowmCfbMtmxLJ4WEknO1VEX3H0G+Y9RzWHIhe2lXSE
# DATA N+4RZp3uuWdU1nkUcb8TqglrWrLq43ed+AQdsk760l6yz2jQrrm9di3unJbd8Xbvy9Auhp4FIQC8tCnCiQ3/gbKbUynBWmVv/PAT
# DATA FuFtbO601zfERfw+eIPppqWaiGpuhvzdA9ORKKGnBRy6mGCkmhLcAMz78Ox4MYU7B870voxT8oKJE0uUk/AByIwRuwJPJ2kfCOSy
# DATA SP2tG7IlpiTMACVO6jfGHAyUoogL1WVvaRnSj0DxfK5bfnWHO6mpu60QQlM4PlwaN8zFP/k8Fa96AZyOZa8C07Hlhqg2qeGLqOka
# DATA fVmSW10DeTqRs5UBJo4wqi1afteQEIccC6AKx5HJdfKAPwCLy7c2UHVTiOsY0uVfIV4lUacdB4RhjmLOjiO8gMmAR7rgGfFHQVm/
# DATA awYSLIDi8e2lhZQ4FXiH496wxZqMn2RfjJqg0J16o/Fwa8fiTKrLODJRC8GOCwmqqvoBSOFmYgGT8MRQzKQGPFx170B72AGoZkIH
# DATA YHx2gKS/aypgyjIujjk4hdb81DiukuHVzES7h51hknuizhgJAJE9yIQACuNOlzBxvBxG/og6U4NxpgVzZcl1W2vgIHD34faHCf/P
# DATA E18gFXkPJ4dZAcTLQyG+9X8cmTuQxl30LYavljX8J82lM30ghqsz+XSSj7K56dvkbEjLQZxZ0ZI65M57sulQVRVcLO8XEmXJuHII
# DATA mf1g0ulFOc72dA6PDMfLqcTQUAlhzj8NVEgUo8ftXj9G3DILaikxEAghlP1EdgENEmkddYaiuh7ZvJBYZ45ja+Vevf1g/V4DXUxw
# DATA OOsNiyek7gH4mrID6KdXSv/sTZ775Jy9eQx1oC+GOyU+J3n21jLOXu/LmmXiwa2+pnt1nVvkcBiEbH/2wC5wYNkVOKfWdzNOrXOt
# DATA f/4TQzmyufIXHRQQUEdh9nodqibrMRa3qoVtra/Ts2LGIhpz4urd7D3pidh28mukUmyKKoWwGDORClmnVkaYNwADNAAMTWiOA0vK
# DATA 9mshxXsKxFCrtqhC9QOjLz3oPAElGNAAFHDVc/jSXVD+oFIutT0GqYNTRYt9JZZOIVNWNOH24UG/F0pGKx6B6KDOE0u7ZDl6+Iit
# DATA cEGsKovwZghm4rrY2GmrCCKWl2rJUKc5v7unOllyiuqegpOwzDefcuvpzdunu1zQF9V1DhJO2eLWgJ1AExkMBQC1trAAi2zJChcU
# DATA EK78Rngu1nzhQ8w5lIvVGRfM5DGW5+5IRv8EiAHoR5jppYmg1mNwD3TUUjKmrZCTSotuhe3uJOLoJ5RIZjNLis5DJBQd8GfsF8ht
# DATA w26I+TZEkrrtfgFL8bOAproGtRjVSXwvegSS1AhD3DRy79bM6dMnl4L7NpbQEDWK/mvfFYuuava1/CrnQPel5ZNDrkTivZTke+X3
# DATA iEuJb77DQ4lhl+HJ5BjliXBVaeMJsLW5en9djy2ZfpVOXKmqRFwb8AkNWxmrif4QXDGtZVq9uCdN5YL63PKfhI5sdJ2SvvhlghNw
# DATA KIAJ6vWHNePNtfr7Gw/v38dfQC6Q+4/yTamvPhHi7cWFBb8MnrGtVzcfbN2v7+DJb2/tfPSgoWWkPKEzpZ8zjupiEk5/32SCfnLi
# DATA AHmCCZg9RTJcXnyWIsiFBCvc75tbdd7vXoGDOZMB6tHy4AHl2GOWteU4oc/MVKv7sX88F60UkBHUDd5ecBPXYD6ANmk3eZykrrf3
# DATA TxJ4PaFzZ3HKrsSemg4mNazNMPb2Y0ZHty8r0IWW3km3ikbGJATn8SrdoMUkwQE+T0+IQQHdCjRAzyDqiB4CnNneZPQ4huTErLUA
# DATA 6BmggGk0OKn4uWWaOiT1wp/+Yy4rS7rgZpGHxxIjpstY+mqmG4m1ixi2nr1TcmiRQZsvt03NINRidps4ZLQi2qdTMo/T8WTCkYfw
# DATA jjYLnjNEtJhWrVeXfP0657wMO4/E4NHNoapeYtdydq5RXdJuN1wweZFVuGaikAvCZshYNCmnptmvK+89kGzKDZUjA/P9BLWRnRkT
# DATA Obbbhf5wGPmCcvE5xoky3AG5SktHa9eGyzigCFheSoKQW4A5LkgOTOgNj9ziFd1dhG3dTwdnW7RWQEwpmBsSLozfN+4WM7ViXoFd
# DATA 5iGDhoWotb6ZomWy5y/zdLOm2aI6T6eStxteyyfoM4B1lYLrbX+Aq27q3D3m9u/j/dI60JSWXvo6JO/e9EsbXflLxk1cx1Kgo0kp
# DATA 9Wp+ca1zitplFnv1G7Jn6XItDcWl9JkXtLRndTC1c7PQBS80AOXYRKsO7jxytV2Gna8pcJ/YqH9QbzgNvRlsDiOFqYuCxo9GYqCd
# DATA AfDj+Hh/v9/to2MXxPXJGEUI0QKtA8xKR1zgDvsxgtokQtFNoC6T4zG6gsKjlDAL1fw8jIndgulqgguUgXJZrJbxCdfeSg0Bvzyy
# DATA VzbCV847Q0q9GUp35flKFyafIl26vmptu+vPyqzHP6YLKeJTJZFvRv2epupOqOT9DjClVDX8TJ39N6OaN7Xyfyoq+Fwy7lUq5Gc4
# DATA L0HAuVXoXGr4TAK+KuW7oXe/iMbd1VunneiX9jvLhU2eobPuD/dHPs08h5VmwYXrSCRCAMpdR3x4Tj03/G6aEHza9RkkV7wSxTn2
# DATA grXns0n4ihXnbb+N3lBrEpUdVHOq41DTpFXsPGVRj5gvq9WxN/aphG5gQPo1Y6b95zdFqblZow0Qgc3NHY7HsbioLsGC2N9s3rXO
# DATA SROHAIOY2+sb72623xUbnOsDyi6mxpN4Kqhv7DQ+NGtAwnYcuJxlojMdFknncJg71/3f3p92DgaD+PTIzVwRZ7/SiXsot8+nL3+O
# DATA ebk+hq+WB0PKvUimBKxlwEzkUjyTclsIANC/sgxLd3TlqvIWRhTWIKowT8jPTI010jKrq/Gz76z9TpqqWoMMaFMi0k9KafRM72mY
# DATA gCbxArVB/EhIyh2aXvdXDuY5UrTuX3tfJqbRy/RUfTytcmKbp7LCUxXiIV7h3/wb+HR3eE2FAKT3w5dV2jiYEgMKvquvQt52i+dy
# DATA 9ZEbEy5IjfrK2ofhebpyrmvZBa5nloM9U4FaHM0q36jp1bugo5MJ0uBpHdlUIsoGhAL1y6yb0YWbfzO4S1plaI9S7CIu/lHnBK5b
# DATA mHGpEwwjwI0fU5YYnWepMjdTO6vomSe05qcrqaKRpSQZKGEXq0tng6+IO/+rZsZWjjXIKleFXJ2QZ+6zsy9f/iKgk1T2mtLB5OO7
# DATA +gaz1xGSVck4ugwrpgR49HNj0zj4TbHlVHp2tytsIf+yn4ugGZuj/WB9+8HKzup74WVWmRMrwSL/+9mvk9lSf4+ZUiGd3j9SCsFw
# DATA xqLOvK7lMXnOEvUcs2u2kOevOlXnQ+16sp0knX6yUxEVZ1bvZs9x8j8YaXRch83Z6XSy/Qv8lgE70QiExJk5iry9Pk0Rly9g2MnU
# DATA Rr1SI/ibiJLGVw/CkIEgwgA17L1g74RiTMej/nBaCbbEJEAgcbCFipb5YTSFS7anVlY2QHTqqIT3G9FG0B2NIa+ZUnT2+p2D4Sie
# DATA 9rugwpyO6HzpyrToFzLZp9jj2yaEfX41qLEdZpq+LsyLEuRPvs3cMuFw6EMpV3h9Ck/7KpWxyaRlc1dJzwlaRsU1LQoG4G9/uL1T
# DATA f9DeWln9PmRMkZ5N4iK49XAnzBqpN2+qsQdW8eTZsrfBsEcE4Bjp376V1RLO/6yMrcYxJRO28q3Xq7C6kHqPJ84NeHMSoV/MPySX
# DATA BAXXKal4P+rHYhIObPCfhEoptbTKATPsP9lG/MWCmeOysnNIKREPHvSfrA9LVgLMCr6EvIpelekBEBigPcVXY1M5A9pAsPbwjnNd
# DATA XMRpMKRo8FLQ6fV4v8fHY9ErjARRLxY97wB6C99OC7cSNklP3Qo+SvS9gDH33BeaEs4fWvCnFS2aeQeIHR6JOkU1rOpMmFetTUiI
# DATA BOPBiYwlE1ughBhizlt7o96JjauBhdSN02OPiIa9tsQVLECptEIEplgIVwlCswyAGDIjpgRU9CgpPRVYEIslhFhEtIUwb9P3o+HB
# DATA VErcYMyCcbv+pvi6fjv2jf4xGqZJxMA6rCk/xMVLoz8zMD6bqEw4AC2eEW5DHuR5nykaYQVANO1MojajBWBveLSMj2CCEhNEgvjP
# DATA XQQkxpsPtlBMt+ziuYeUt7xwEwQsad4K391s3F1fW6tvhKc5VLzydiGzkYKP5r36Dnnb4i+kZoZ8sSRHhNn2cN2xJcA0o3ljXzh/
# DATA iGyO9ikdQQyCTyGcByU3hfbPp/rZZvVGabGharLCOnW2rranB1FqRyU6Y0p/6M2WhHeaz8YFJ/xEuB0uvboIsvQ5xeYR/Zw+LVx8
# DATA GongOJr3/L2hUPJLtm65I1MU7IVo3xN5nLNnW5vbl+3aADmyojCDCbUhgWOSczdbmSTG9RG2tArztHjbzqQzjPejSbkOhxvFCrL6
# DATA jd8WlFHpx4I59qdaNbcQfBduLQVdBlWWNkjulREz43waCIi0enjuIOyn05dipjuGIcJCzRIRDudnynihb4ALBOKdYFw845I1okd9
# DATA VC+cftNb1keY2NNLEiduvvlOl+Ip/zKpcunW7b8gooQV82A46NCwV0GbmlNz/D90qCn70iIx2ooVko90v1r5yX7pQmdDKpGTWPia
# DATA vP8cyNtW435DhG3SdMI2cxV0nC5TW5eDZetyAKa7dzcfbqy5l4NXqha1OvQd8uBRCiDYTqZvKel7lsU5laVG0mO6gC7JXUdjLnqj
# DATA tpAHAR7OumOavwNP8BcgtYp0zKFlSnrNQymFCGi8oqD6kISN534sQOdln7XT/R2/FmaHLTOm4Pbm6vfrJpWb9Vkeo+hxYyqfplIB
# DATA RS46JamGIcx1LFT1ViuBrm+bjgmsqMJ/2vsjTBaECVb74A/PyTWBjtptkGLa7VBmPZ7E6Mgh9h9+rqxMDo4BxnALf1GZtsBC2hYy
# DATA ULfdLhpvQn6ydodfKWgXR3Te3EINOAMN4zdxPxuNp/PKZVNabryVmSdt93AEyMY1AjlG8VA7TTrIBgiTLoNOxVSUJRImlpWhJa3M
# DATA Ycg4yMxCpDwv3kn7fdDZiwYZv6OZLbsJ8AZNrwDVphm/M3pvRgnGpeROcDArl8V/oLTUP0GoKh6m0XGfbawLLrrkNrr51p/AXbxx
# DATA TPluyK2E9raCrYZcIUArOqmCaKhih8LqOKC5NPMGvkXmDfwoJow/4erwZ1wJ/oyzLtHR/e0SBZk4kwC87zbFwU/4mWeav/GsZjeS
# DATA oE4L0s2GcHWbztUA7whdLWJr6rqKFXRYldOWXZm5xzJq1PgT+BC/9nt6bXyo9KSXdqsqzn3r9d/rv9d/r/9e/73+e/33+u/13+u/
# DATA 13+v/17/vf57/ff67zJ//w/k1Y03ACgPAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
