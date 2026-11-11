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
HELPER_BUNDLE_SHA256='8bc245f4348747fbde375fe86aa2f7f14802d70c43439b062c4f8365afee6758'
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
# DATA H4sIAAAAAAAC/+y9a3MjyXUgqs/1K2oohQHMgCDeINmixhw2e4YWm6RJ9ozGHBpbqCqQpQZQMAogm2ozwrZ2770R3rj+BXsfcf+A
# DATA 7LWutV5L+gvd/2jPK1+FAskeWePYtdrWEEBlZZ48efK88+Thwd7+0dn+936f/+rwr9tu01/45/5t1JuNZlf9Jr93e5329/z6976D
# DATA f4tsHsxgyO/9+/z3+dErf/fFi/3TY//z/aP9091D/+TVZ4cHe/4hU4b3ZTzLknTit6r+lv8nwWQRzO78Zr3Z8by9dHo3S66u5355
# DATA r0K/+afxeBLcBjex/8Pr+XyabW9sXCXz68WgFqbjjZl6+iNv/yae3aWT2E8yfxrPxsl8Hkf+PPVD6NQPJpEfJdl8lgwW89iHtoNg
# DATA nozxYRJnXjr059fw4igJ40kW+1EaLsbxZF71obkfXgeTq2Ry5Sdz7H2Szv1gNEpv46jmeb78O5nFwXgwij3v/Dr2CQ3DYTxL/c/j
# DATA STwLRv7JYgDd+4cyBHQU+MNZHFcJwlE8nOvhh+nMy9Lh/DaYxQR6Or+OZ/7rZBJlPsB6m85eZ1U/m8ZhMkxCAObOj+IsuZrwlKGT
# DATA xSz2wjQFTMA8Adu3gDSYYwyDjceLSTK/85MJ/xDAiNDpJJ5jv34WzwA9vhq/xhMS0DKEzR+n2dwvAHA6C8I5wsMQ+vhUweUBXPPg
# DATA NTS/De78u3Qxo9lH6Rghzq5VT4TsmCCjTmq+/9kdQD2Zz4JsXvXwxWKU8njJZB5PIsbDFdBWAN/j/Hje0niAQ6QKpExCcQCTSa9m
# DATA wXh9HToaI+CIUyQBILoggVbYnVkmxAt2kswzfwE4zABxX13HgPkYFyp4jb3iKxpxVXyEr85iIJQZEhgMJUBWkcy86QymBhg4fmTS
# DATA 9uIbWOfXwRxn7l3j/kGMWhi3dgNvgiX4/LLgZ3bFJAk9jP1kiF0CPWXXlaoeAuYQxskNvryYhdhlBEQ1A+Ka+FfxnHYOvejdwoLA
# DATA V+tVbGOtuh4eXgdE+gBbyNBhJxOg01uP4JQFgo2AcOruXk/SW91vlGKfGfYM+MU1eR7fxCPcFxm/gkM8RFMwyjwO50xBxJwyjzfT
# DATA LZDtPAaW5JcbFT/IYNHntJeZhaUTZzoMZblZgZnAcnsIIfEcxRBur5Pw2r8CJGYE/ii+AnCIlWXEMIWXVa2l86DPDdqQUTK8c8aD
# DATA qe7CXoaNEyGDHcD0hoBAQGME5DaJkNyQXolWS5oyEkaLl4xh4jcxMsEMSCrCjQXt5/FsEjAD1VsFR5W1qOIqw/c7T9HDbQK0OQXe
# DATA GOFIwE8BojGQ/U2QjAJgl7RvmHtE1sqkXjIJ09k0BfaFG+BlMLmzGyzRKv7vOg5msPlhGwBavBg6WMyCK/g6YNTM4mwxmuPELc4I
# DATA nX8BrBwmVM1xRLO3AfII19NlkVmVF5C7BSTd+UOYFa8TznGQLuY1LQ5WyAGWVYjj17QkvJYJDCg4psmM4jkBTrjmDoIQtkWGmwLb
# DATA KLaNpAnD+jghgGwUBxlLrsyzt+Y8tbqqfYDM0pzGET6wXixziHgIkdkCqBkxSWiKzbRsMJgaMkMOngCmpRQszwGy3L9YJIBnesZL
# DATA h2SDbDontgASJNwkUszEYkdDFxCF39liMhHczhRmPNoW/AowCe4cYDnHNkCyQMmyDAuWnsvrVoV18QJpBjji9UqQ5rm7qmz25TUV
# DATA JDDw3kPA4y6f+OkogqmLiAZ9AtYEZQG0f3g9kbJo5Oyadwk3B8EUZI5MAbjS8RTb+VkyhqWa+VdpMMoII0AVSQYzBcjgbWAYBhJS
# DATA lTSiZQ4KppNDVq/k+3WQeUywuIGRza9+UZil2jvwGo2Iq7gA4Y+iymhzQt7AhMIEJQG8lLHoB96YzImNIRdC5go9WPxV7T7Gesia
# DATA 1DBF3Q873T99eebvHj33946Pnh+cHxwfnXleveY/B0474Y6h2dq5xeXXWNjTEqvZtdT8Ht2A2JvWkdeAHWcg7uMA4NdiZ32UgPgf
# DATA Bbci3oLplPZnToX0lAqJuxQWO4vHCaJjEeLGGgfZawE9BsWWWLsNOTJjPSJxcdqCgu+I14CYo6cg9/39AIaSJqz+RhFsaVrtzF8D
# DATA kbcGrdbkhThbI9Sv4aqBCgBiaI1Y7AAlUZTADl/A/FFJSGdXwST5WaAQfp76aywQoQuGjJGkjIHhDAQdqmtRMCVVHr9MQXaohcB3
# DATA PJR3wNCza+IRxIBYdCgBb0RzVbALGGcJIswc+cLEi9+AVkzvMQOx5BABB6iQHRsI4NYGXxOYPJBtowQZPL6CwPOntUHAwmmNBrZb
# DATA kQawFoIUn0EL/GVNEBEnAi6ItokeURba6pz69kSRkceCYGCy0+AKhPMyjiMiEFK42OwAEcViQYSTZ2PuNl2MIlZaUeuJgM2HcyBZ
# DATA gEJpLwl8HSVKW4CFGeJKkG4ipIZUDvsTW5j1gU1Q9eM3YQyLHL+Jw8VcbDjc1R4yNNCgkHxEfWLxCyr3TcBKMa7XicwTiQBUktEC
# DATA 2KLmFJ7DKco02dTIYJttgK6sJLxWfUTUMO9n/RAFJ+oOoLqAwUNaOS0V2lU3wFJQVmZgN4xGsg6AoZs4T+i4P3GnI+1MrQkQR4gn
# DATA OLh07CHZY6/KcEhnWpVnswCVr1jsKjLvlDEZkOoIfc7SxdU18H+NURHJvN4gA3ww3SbZMBaJzUqsGNIMP+CFJZke5Sbm7umHYQAy
# DATA HHA9HQV3wCp2pzipWYLLdEha8lEKZiewDKU+xG/mSBw0X7IaZOECHm+C/ITwDR2Nkwl8AxK7SUg6e8M4mGvzCVV7PTLs7sAa25Da
# DATA hMbXKr43hwViwS44CuaiXtC0Qb7O0DC9I7mjOI5fFmIVurAnIS8kYu+JihMpC0yx1YxYJOOU+qB+DTtWgoQhvQZDCeVQAqKWl8VX
# DATA jhDDtg+GaPdZ6wByNCOrIIBhM+KZNElU2QKSLrDOU2LGRr4EHuzWRZXNasY4LAyak8xcqKdxHM8zHj+cwdMZKziNmn/GatweaEIi
# DATA zdcszW6NjW+HDbHAR7saOBs8Hju8nZwYvB3tTUrbIJmjGDoe/DQmro3dm101SSfropapTgOL2Z7NA2RYkX+g0GVetlDI+5CZcELP
# DATA wCZMwiQYeZnqIUIlgrWyALdkegUyDtVnaZD5gzSCfZQu2y16oExp6YwDxD5u93CBCpyYbGNEwgis7wWYSqizxmIAZmS7wb4g6ycY
# DATA p9DOssBw0sRPha2oLtT6nN1luL6HyWAWICNbY2konNgoDbI3tcgQWeppWUqtkIRA6UtHsVB8Oagg6uTtSKFgAosC/EDWBrhb+Dq4
# DATA Ysb+MvgpoGAPmFQ60a491iOFFxkVAAag5p7VnPb2oMLKO1D5hPUqZqfKDNAAi78NELk0Lm55IDPQp1mEBf4y2dByMXCgQei2Ioey
# DATA JSGiDAiSH8bkQTwANe96azko1oRocKulMOgbgEsIFTYGNkXNDBgOIDNUL3nl12D+xyNk7JMImEdGa8yoAVUUpJzCgbIOxVjDFeDG
# DATA XjlBMriroBTmCTLDdqkCbLKsypoIDp+M4hnTIdt3oKcaFyG3gz1ktizvNWAAc/Me9ombW+hzLwXWkE1T9oQwg3EYSeL2SCQlKBqN
# DATA vLxxOYlj5XQk1X0eI4Zhs45GQjpDhtLMlJhzhcAis9YajBxaqe3W4YkyuRM2gUNO5+QpId9oOoJmKdp0WlNwPBtzUMtiJnO141S3
# DATA pczLb1ZCKU9ktD5dzKbY8zxNWeGWB2jTGjcOOkOVR05RrnKdWEomYBUoApHJJrcLMu5Jz7zsbkqGFmb1AsnzTYCbouoXraOnBb6l
# DATA PmijzB8mI9KjsjREOR7xZpXV5Ifi7hS0s38xzm8t9lpHILwEbRxmuJsEY/aLeKNk8hp59mKgUaN0Aa37r/Tii9Oj6ikhOkCf/TwZ
# DATA o+4RBfNAeUnEMCUTlklhCBYqWErz2zieMJI9GwbLYw/YzRz08vYowirRuENBWs1XntRZ5qHXdRarTeAHi3kKAMv02PJaHtkZzuPh
# DATA HoLE3aZ5jqedmFkw1rNq1vzPggw40ok2PtBY3AXrj726/hXFCqICdYmIUT1WKhv6EVDGLHl8T5QvFNFMIQmYwU3K5onS3Jie5kh+
# DATA nuWHwObjeK78Kmr8+A3aNwlqqQFoCujAIH/0YjJKxgn24fqJFU9Ztu7EBAXzBHR1Xg/l/0KbyNiKZJbKd/KfWuCQ7GNPr/TEvqwJ
# DATA +RlJoKCggw/ZPJmDTcCat+k8Pz8Q05P0FkzgK3Z+zzxZE/TzBgkHArSjGPfFTTBiqZwZlA7uXOsPlvdrMClRJUbbpkpoEa2fjVcH
# DATA qMzEEMCExfALK9LabrUdRiDuRqgRBbISKnRHEN6in0nCROhHAJKhMI6CRhT03ODio8k0hWUpEgxzXwxRXgc34qccs7Hm6q5gPYwW
# DATA GSzDiO0KgIv4uPKHUvQFOR3ww2TE/BbbGf8nMmNxDFl0qsI06AG8I1x4iv6zvMGA21GbdORaQW41S1gnE7nAGPbE/COGpdeNKIOk
# DATA zfVCO8UdIHOL5slU/fEiQyGHK2NjAjYELdAgvg5Gw6rsbvqJfQ0JumnZG4igVGkb09xo6oCI62RALgxAO20YZcizF4xDZx71qKcR
# DATA R2biQDmZ+KMT8snzel0nUxY88GYNY98Ka+LSgN6Z3MNkFi7GqPejRu+Et5FCUEMXn2fsUCgxF5g3eit9/4wURHGSulHsZ+hpIRHS
# DATA qHtIWBRVAIRj4C0LZncAXquGHAQjYfj+Kw4asfF9ylv1BaJmF+TT+h4BfIPqI/R5SBvxKHWWDUUnEMcA5TJotpEW86ghDYcxewBg
# DATA uOtJOkqvUHyABRlQiMHgx3L7wHb3h4sRSO8RUQxM9kr2hbRHwweUrkZDCZ2vDk6OLYYxn4HdD31GYLxyuKdZ958DCsYDeL2xtdXF
# DATA 3eQp/ze5WBVxKCKN0R3EKAodJMCQKMXVHHRwmDcWcQOXQ1Y5yhogGnCqEg2E5SLrAYh+kIDkyA/iYMxXo/muW4RDM/araO0x2pmN
# DATA gpI6CxMiFWHEBUKRiBdlM6qtoIfmtyYLQHbqZeEoSMY0EwrQz0VQkfjyTZoCINhxttsmFdmArIHDz/EEuSoZjMDKUdW2FVrSRaq8
# DATA zYmbJjOmMditJUGmzExjc2nJvGJswtq1a77Zr1+qZJI9dpgZqSMrm8s2UZMSiVzKHAWGBYqOnyYcTUPEwTZJFuNi1jzJpmDWp4ts
# DATA RLkunuWmgl8kxoM0HaMXXlJiHnRmPfNex/EUVwu917hZ+XdmLFrpc9UkVHgmdx56SZRCcqMjLpHY6RhMmimlWxhPzwQqmIyiBwAQ
# DATA /AUDsFBDjr4BepRP7RmBcUUbBww1Ez9Y4eOCVqnyVLt+br2MnAKBg1BCBlLUJJXPKH4MUu0lQdXBU1sA+6HAP+y+6TRFZjczbkBJ
# DATA MuDwEqq2wxj1345NZi+VJic6sORRFdCb7b1fUkpFt8i7vbRVnYhW6Lwk3hXl8rLpVTGG2NMKgVrUdhGtStAqlsDLUPIzjODa9ryg
# DATA Qkoq+/NQrIeAqDvLdVhIioRmQZKXiMcG6IDdPxhavMHckwgzCjxv8K3GoAwwE6YsMhV4D9iSmCmf2wpuvJ5SgcXKI0+QQJ9JtoJ5
# DATA gEaOQiou1tqKrbEGEwsrrGfinJRWSswf2NpMW7SWP205WicxPvQFQhufY/QwGtB8mmVxpoKygYlqWS/fggxmbzcGynljV+1dlhPd
# DATA mgd4gChCGTBbIqaq4gcEqS0MxLiSfCuyJauwLFfBLBphBB21ZfRuX+N2QIc5OQLjKG94cAR+kubsJxtvyso0CtltcMfeQ8urAmo+
# DATA mCQJEhfLV6tDSZmiLKwsBmCZKwuLj9gpFVX8A0vYXQfZA8EQwAzxHNZ5OTzhrQyLPENciB/IET35UWzPMZE720FqBH/lCCxpOdqg
# DATA vQRkopDWTFo5ecjZmadlu6vzMHUwjhWeJCoWxVPM6pvMVeDadRJxgg9o1xMO3ZCi4yQoOYoJcWW3BwBsQP52FbFUThdWD8YY7UAp
# DATA oP3mVTTs0CTFMPFNOlqMJQ8km6eYdYTPnPCgEt9WuHfirQVXV0i2GEdNFKQGRTT5eeZkLikxLZB7yr3JqhQJRs4iAQAcRSdd6r8k
# DATA qYreIIbNjigR35SJsItxyiYHhoMmZFoVLR9FzOH/1YyMxzEMFpyCZzYechhb4ptopJHvqiOgnK4tCY9AvRAh+AKWplACuq6MAleu
# DATA llvMajwjtzLgsYj4zkrxZQXYxrANgW7WMcONuFmhvyo3WF4FYVqaxEYcAosRQbinx8o5uEmUg3ECMoP0KgquXd9lpKuyNJ97ZeMx
# DATA tp4W0GWlKkk+wSTRGXNesfMtecN6ReBHixl7tVTP3JkXAl9Kxxy5J/okb6lKpyMuwxmfLIj/zeYYeLcztKQnrJtVfeLhrIOB9AQh
# DATA j/sBEw3v4mDGjlOrSeZZPiCl3k1Z3hAhg/FOmLDUPnbusGOBwAehjyEVjByIsafkrghblfZmYUZih5R36hml9iFvKctkexE4+YCh
# DATA EO1mpcuvWrzeHiPWf/J6V1UcknRnkLvjlCPt4qWBbZSlE0nk4OCyGgvtGDtykGSe8TRppZQoBrNsTSqdKOarqBmV3aU0wgD1P1H8
# DATA WacSGrU4o2vN2csj+RHWwrh0hlDZWYpFgCmtSuXckjGYKZcNu2DTMAwy0pfY7MPwNMYE0HjH30hL8pS31krTjopBZpmnN4O21Tx5
# DATA OlCqWnfAGsuKjTsQW4e2JK+DoJnjG+T1Bo0C0F++QsuftgpTBuO8wgoeY8v4e90EyeIFFVuFff/BnUpQMT/ywLTC3nAxYx8brzS7
# DATA aLUGIyq4b9mQj9JTzpq00ELJFBysJQgodDctYHvZEj1WV5KJJzlxvD11BqaQcZk9K7yfiUchio035K7icX4rM6fMRrUkOVneYkse
# DATA skmLBkgy8UJglJY3FWQ+6F9asFszywLq8VYl2g4TDqx5KzbAqaPQ35pMXFBoM0oVKX61KrSOECpXoH0yxrbl3Ex0YOWKpZuIboYU
# DATA ynHYzLHLUPOIV+6CBfnPpnE8W5+n6/iXE6F06pvCJp0FSCZsXXNwLKYUC8ZTQWy4KF7m+spmmFzNnHFIDF2WQ2K3OuGYdoE4OMRC
# DATA tbZ5JKcIUBcnvg9EYrnlLLBQI0e3ve0aSCQmgVPUPoXiTYMk7wShgXfpbTjQAd3IjS8sMTGdiIMOarRyULatESCWxKSsuWwxZmWe
# DATA miiDQmf6eHM880VzhqUgkxRtnxj2jJ00gtkmtsxTjUHOBWOQhlUvRWKF52DBRiqYkxkppSKoOvBLgnPEvZkzEOSjRQMcNjlm/2HC
# DATA HCrj8B5qlMlE9hUnC6ppMSvJT7bqReliMB8uRpyfb3zxsDDp6IaxPAxuOMWeNIKAmOOLXA6R1h60WKFsJSvJCM2Lqr/mIMrJJPbm
# DATA d1PS11LOIAPi0qk0QJzhKODNr2D3XSNfRVEXcoYvzg/u8yRoYwR05s0kneSaemAELxSUvETxG3Ruk3QiYp6yhxwAp8MscvIFAcMs
# DATA G63SFaI9B7laLKsPMsdx+80DyrzxjCxHYRwtUKNlVKGHVQ/A4C4m1DXJcPwFxpNUPfLMkxaANEZuP3Y2xZK8Z53iobl43toB566w
# DATA GXpAvIk+qxQZe4NZ+XFjmFQaZVWkjDCO0F1exRyA63QmGdr+6/iOkcusLjF9K9ZKCJbkGTLVOWdm+fRDVuBDUPloDoDIfbyCozV0
# DATA qCxbrX/FDnjobfGyBabqxXlhIsE3sNEXyAoWE+Kgopo6JzeYYXmKQ+KJtpRT92C5MPjATIBdMTwvTk+hUN8gJmPajZIg3Qww1QMP
# DATA asHqHQydwNJkiUnajkvF7MXawsE40GXnpQzlMB6bYDZuTXaMpY2H4QKtpczTYT0WfYEaytqFkjsxtH2L2KWhS89ZS0zukHxiS65p
# DATA FU0yjKbxfIGHXJVe6bHVSkkb5UJHoQthRiohfAMt9meSaLtC4+N5u95ghVRy0A1i2+705DTaqh2GB14Xc3W0zPiAtTeF/CZegid2
# DATA WajhWk9SDolauh28PaeDqhwsQSXuzt5ZOYqUQ1KsPTsYp9Q1nXBluyg9ojrpkOXG6fHLiqTu2NBbFs+qiS9nqAVergu1w+zulGGN
# DATA miElYauoCpHzYoouWc4SkLgI7VezZTQWZtZE9IlBoaqqEJK3hBxNy8ljnaKI0OZL4CkNXxT4KCanxO11PFkK0CCTikdDnVKggnwR
# DATA 8rGYk4JITpnjcZaWpgYCWG6SdITo4MktRpyyhsx6noaY3TcUMWyyyoJwlmaZ3RElKzywD5gjrFxlpfWS08uOBRZuHD6FQy9rH4U6
# DATA UuepY/qANzqrLNEFP5cvuzpZ1sunjondSaMr6w/YM/FCVAFBG7lFgAFNIMeIIhYTDC5QIBqdgJIKINYT4KpX83dNXOM8ZoflmvWb
# DATA CRXgoadZbKefIHVLnvCS+1BHXAZ3KieFTxDwkTbKtZvEfMBlFithZwJTNa8YCDk5JrEbidKoFAKOIqkAAqmOwAU4e4KPcmGuFNvb
# DATA oCrz0RE7Sdt2Kjl5CZ4SpByyYT/b0vkezOsiQzoohN1jr7LKzrazR3U0k91v+ET2HqnvJjLjKUaeqvO53DcHfQqwoCoCXKEiwkn7
# DATA 3lKqBCaQseBR0y6ewYrUEHYlFSWJ4CQCOaDOBy+AbY5TSRwpHkTFeIO5HMdB9kYuGgxyM9I8cviXV9CIoE75tUy+qkRi0lsBA95D
# DATA ow0sJ7TG2eK4VRPMZTjXKiZJjpwk3grwkUMIM6xKfFU8HGQjudEeN/OMwnCqNAF5XAuzIMxolL00xyWksxcq9UuVvEjx3JDitjZx
# DATA 8yETSQLDnA6AswA8vYaUGS+qshFBBqJrOuZLyWa0cKrvyoNMwk3XoUccWHguSTlkOapEBIwZYRyJDoUkSmnQfiWVwlsU7s/8RoeY
# DATA Z6ObH/sZ6pPo6D/VxyjJNJndaEFlDqpYLmAOX+m0D7DQCD1A7dq1n2mF3+TbzZQPcCle6Um8UkU0Gc0c4kLdImBDOpkzxGEFt7jO
# DATA 8AJ60DaVI2Fhxa6SiTZaDWVCJ+bkKD8rMmHIZtPwD/D86Ow18UvPwsYtHUHLLC+fdqowAIEuYcLgRxVYAFlMOYvGTgoSf7iwyh9B
# DATA 9V+CMX/g4Hc6szCubW0FJA8QVzBBbsRIwwAGElEuY2wGJglOhzP0xIwgd/0YaAif8shV05TNQ9HnCBcZjze0KQiDwuOJkypmIKfs
# DATA ABv0YO4ZBN+52Q3IYzNnen5ZnQrNLRXwxArvJK5IQx4DPEqwGIvYJTAsbTunRqLGQPl8po1IPU6CKexTH4oFxSal/GuPhVPhhCWr
# DATA nflTLhUrn2FBkhYdCaCRIUdaE4e4p1MZSSnBGcueQltfRVx01qhxbSuR6KaxRZTHJiaKkskJp4izjRLINi9Kt7HE6srMrYBNO6Ui
# DATA gs64PBHDakU+MupjOiOFGsVS/ScNn6c79K0OSR8oKkLARzGcfF5bYbPkdpFIMGToztwKVdunPq1qVW68mlK2CqBGO4uyr7MFbLEb
# DATA SVhZBb/xJxCwrJqmBW6XVbo8zdYjlZpkuk4n0ylZ9tGbKqVQAAII/+IAWCJbt7YBbwZ5nQw9ISaM1oVET95S0MFRbkUr311KQLL2
# DATA TprfTVWlBEmqtYRUzcFQK9lH6Um6NAZyuLlSmY3a/sxjax3J0440yGTF4gdRANBu1sicSCbsNzBZEHRuSp9xMPWBcmsmx41pfBRr
# DATA Gai+moKWU9vQfkWFEuYBjMk66cDGuB7Nk9G4WtpNmohFSHlh7nmguYAf2+WV7BIeaqfbMX5iIXOrzsjy0Z2Y/SDofgrg2fTaYVcN
# DATA dFB8YaVEkaqNGX1cBoyM5EKVbi5668zTpdo4rmm5kvMKm09+HPICsKFa8bTSyEFa8dyS0wsMi1Gh3uecAQKbfZhMXBS6B1HMeVWk
# DATA 14CPuFdNjpF07knnWLiItjVunKHECrmtQQcwISpOYOkk5PnFMmV8qLVb9yPSUoZzWQc6QSDk+RKs0JRw7hyZeRIKPQuF1oyWJqTe
# DATA oHkkcWbNxHt8JlLRKWFtYJjMMP8jGcfacDACTTgMdL2SXtSZT9YwK8bm8vLgmlT5cCEhP9Orxm7Lxq4n+RIAzlSbuAwUut8MX8Bn
# DATA S7vLdbZox5vZj4gvvb3QOSt1IlBjIgtKI0KlQegBaJo4l+V9zHLWhob6Ip+ZHjuSVIa5vdDW+letI1r+X4CuRBZkqutWYOUgp1yh
# DATA ivwbDdDJxUX9xfO2auSdm9IxG8xrFFVTAntf8NkrJ8Vf5Q7aYYsg5BIOuTNRIBg57UMBiZYBnkazk0SsM3q7kxC4ZcAJybp+x3LK
# DATA HXnaSR2W+ECgQk8Ak8qOfyQQ7VlgCTxYRIhYu6YMZdwHGkfW8WJUJiiK6ZTBsdNskT/zXnQTbYvkBmdP5w4LxnJOmC0+LgBj7Xph
# DATA 4nKqrGAR3Npd6DDTNV/4iBwjeekYJBOb6BEipgwOlnY8l7+hZFfUineVtJMGojg/T2+BlrFgKBCZSi2BV6hEkuY3K84FudEOR54q
# DATA 7pRZquyyjaiNhqocFa1q/YB9wbIiXHiExswWHCIgXctBqrsP0CUsRVQwZKCO6PDZwYQwNrhzT+NY+qKpcrU78dfQx4bmkYnKrLFm
# DATA b8dpdCSIR+HDhFx2yS4LxeqWiaziRhmRjRVzvikYg6oN5XexorHcxzieXTHN2DWniKut2qicFc0ZvCoPauIvz05Sujl0Q4gGQWHP
# DATA FVmvtcA24+CcD0xN1Q0wWwY3p+HiKpeeYyAc/r4r4SG2OKKTfuw4ocAjWAvAmiM2BBajyCNPmVGvMFSZpAtKvWcNC1Tl0QLhktN0
# DATA +bMCK8Nn9hQ0sa6ACRUYL/+cktjnuWqjcjhNi/d4OMQEp5ySLPY0cpwCQylT0TA5DqfjkbkD4yjk6VT2KrXZKVggpp9nj292K9YD
# DATA nqV3wUjiV6mVnsZnjQws3qMH141eoWeMNRBwd2NKF1Orm0BL4Z51Pq7Hq0/Zm/SdgjF48HGBbhAMal0pU92z1HJpbBh1ZCIUVZZG
# DATA wFI4i6VqMgWp6nEw4o2ImJlpz5VdmgzHMWlIdHai0aj5JzR2poqeTdhDmM7WVBJMTkHE3aS9rZQHX3QQxhXMVmk0p3qJegwj0aEr
# DATA Fjae7LRFZirjmeR/lTAgYMI+tKHW5d/k1ITTzpRmsREusSPka87PHgibOLKqQ4xs57LuuGrSh0YYx8KClaLWwLqg6GSlXv1aVfIB
# DATA y7dRoM5aa1KuQXWboGqrjyt7y0nFwzxZkOOPz/BKsCqPkqqHXhdR/1SkmKe6EiQKB1EZqpxqpHZ90aHTgrF5L3u225QmZIqLVGUZ
# DATA 09GaKTtm0hyUk9STJcrUqWw6YEXFdxBp7JLLqIlOJXXcARQEcGTmPh9CNDBbSldAngt9LB6r7s1GEdZ30txmnSu4OIa1xfBdElxB
# DATA gahQeFxqgfKjcCVlg3NGOO1u3tqmCAlXS3hADeHRZdqryALdVOqUIuZIM+ugOtFKRJFvac2dIrOHyZ1ygXjQNBbfE4fCkzn71uQM
# DATA FQbqUzFUuMApZQJRiQeyYimUWdaFzyaq5yXNl2qlm3d4vJt4EvDhQypTvhCPPbewKx9WkMmk/hqt8pqkbuccI5xowBqFLs8o9cE5
# DATA 03vFbJfmpQjDPmpN/S5nG+XUVSzsATDTebcR69uTJUD5RNbK9FBbRVClC9y0XXLne7pCNtWGxtxFdXI3evQIjs4TDzxTslcPkjse
# DATA oAUzRfzd4r7sSPDmOsSJjk8r/VQdhloxV5gDehRTk5hskkUxSHfFRkaMdSrZHqHUEEGRVeabTne45MDGcJLZvhZdQavc0iNUbV7k
# DATA PYEXLYf1KaQfCZ3QlhjZJpK2f0xqPVbd+3GeWFT5PO1/keiILhcjlUVRJChTP0davlTmsJKGvSXXtRTcZJ1LeVYYMD4kV3SO0HPf
# DATA ZLmjjVM79SLBo4sgYDiJmjUVFbj0pANzxkz8K6i7MjmMkvgmNkkRtOewAPUsWwScGMVqMkxyEjslOlGojtzUNgxA8TIzX7NOq9um
# DATA MFlqmMW5ULYVtBCbt7pkJNNRa4r+FfEgUgfs/Nw4E1O1qKSLVst0sRuVb6thU6LC04EKnKuqOWdbRku286SARigBn8FHaeC4qJmQ
# DATA xbmDxaLMWRB3CFb3yNFN8WR9/J5U1N08WmCgNayLMUtImKSzOzoBWlSojaNvXHIO5mZl8nBmdlXXIcny5grr0pkpMWUqArBGYAyb
# DATA XKqQ1llMOpCbErra6rAqHZkSr3mDWDw2pLIaoxdFkiFOHdqzkholwudJDGmAeqMkcpojf+QPU/cuMIAmAYQE4DS4G1POUWrCBTKC
# DATA UzdBSqYoH6qUqrvjxHhhKblKcfZ4+b5ZJ6uqItqaTRvnKnMR5Y9b2hvKuVql4z42+eSZPVXIXOYJ7qk1h53pRFZJpSlzHlsSyw0Q
# DATA Yp2nmaoNXGHBgUEGgIOO/3Gi5SQqGlpvUMkzz0TpUMeRM8UPKeZasH0lUIKwxeQRiLgqgRCoYWqePmTp4gTr2gvdVo1fvbnpvwxm
# DATA sFrNer3H2T7XurSp5dzT5ySosNlsoWN3YjxbyTNkDmMaYkL1AcWYNDddDLVLxqlmLekjwNe0YjyI3fxF7Vi345dqmlRqqdGs+Uep
# DATA f7YA7YIawlofU2Wxkv+Cr/lgrS1Xd46dEZFUzPLLyh6ksmoLqljCoQpLZzSAVlQ2GaYwREmoU+LVEEXBtDtVaQ2QiEIWx9U+oNXv
# DATA 6jACenxsFuMK9iyVA/zqAFeWjBejeTCJuVAOZ8wtVYpyHACqnIc6l4U+CZq6eU3EypLn3Xb0CIDA3QMq2JF3CiluiKglR52Jcqvz
# DATA axRFJw0XLHgs+6EsN1J89EFGredYuxXeAtYytkS9l0uIlPMhcjUT+/w02gYpaX2pc3mCgyVtclMoYTjD7cs5kipjzD20ZWrsNFo1
# DATA vOMrhfkdiY59YCqNP8Nca6N1rr5G5dvm6AneTRqip5FC1LF0YoTTGKyq4Wzd6pt0PF1Ow6p+P6MJjsxZ1OVi6ZT9R0PKSJ4+k0m2
# DATA mlV+vUInOughX+RlxW9WFdPUAkzNg5U75el2rh0pPGb6+DFpY0GRuqcLWetD8AHIKF2+S06VBrqohT7FLdcXSaGWQmCYEdt1bFef
# DATA e5foq32wXV+84VkXb6y4IkUlFFnXEUWO5s0ZH8rjoH0N35YgtaGTL0gzeS3SEsuULMXIlKbk3MMhecyF94ysuuGHzxiy2eCZoiim
# DATA DK5d/SJ3k4UcmSrOUafsD/v8hlP+g3LC9LnK5YItKvHazFUfuqCiBbp4C2nodO7Xzp1Se+oJKECe1EaeBCsEL3/pXHTlONxwrihP
# DATA gdyk0MELsOQiOSsWmLJrM+lLLuuybrYRP95T7l5ido6xQUQZ/KWajoACuzuPEID+A6lSiIWjpsks0cexJX3VXFKEmEVgOasUX4jw
# DATA 2BBeY+XJDS00BNAsaBpj0dlAvs0mOmSpKAzQw2VgSTdFuljA/JE8VIvJAqsp6nRBT58jkPRfZWzofHF+wT2yV4wwL4ewNdn9eODF
# DATA +NNZaxLVa272G0HD2fPEniwf4oorg8Slo5LxFKCeBnSmKtM5EPjOhUvzPA15hoaWkyq1ZcjourPuVuLhlUHxKDmZDMTwOlUhMNUX
# DATA uTk1mF4RmBapsy5pg7m0mEA7b+74Pj54Eqm77oYLLNbk5e+Se3wvYE9ybKOqi6m8uStl4rpzEwjdcL1BmZ1GZEWClJrFeKHe1RvK
# DATA w2TUl0NaWqXg65kgYq/EP2fn3FJNKMne9uwzH1apdhCo9huWeppT0vGUuiTEpwU5U6SPyt10SvrTpNRFk0TioDM75Insr1PThwOY
# DATA pL6S4wHI9L7YP933D878o2P/q93T092j86/9F8enPjzwT06PPz/dfVn1z4/p+/5PzvePzv2T/dOXB+fn+8/9z772dk9ODg/2dj87
# DATA 3PcPd7/Ce6F+srd/cu5/9cX+kX+M3X91cLbvn53v4gsHR/5XpwfnB0efU4d7xydfnx58/sW598Xx4fP9U7p+awNGpxf9k93T84P9
# DATA M4Tjy4Pn+zZM/truGYC95n91cP7F8atzDbx3/AI6+dr/8cHR86q/f0Ad7f/k5HT/7AwAgL4PXgLE+/Dw4Gjv8NVzgKXqfwY9HB2f
# DATA +4cHMDNodn5cRdSotqp3BAb6f7l/uvcFfN397ODwAPCFd4a9ODg/giEId7sM+d6rw91T7+TV6cnx2T4KU0QhdAIIPz04+7EPMxDE
# DATA /umrXd0RYBf6eLl7tLePY1lz9mCZcLr+18evUFrAvA+fO0hBRO37z/df7O+dH3y5X8WWMMzZq5f7gu+zc+jU2z089I/29wDe3dOv
# DATA /bP90y8P9ggPp/snuweniKW949NT7OX4CEmoW+OjBzqgdqjy3ZFdHCH17H+JtPHq6BCxcLr/p69gnkghvksh2Pfu56f7hGSLHryv
# DATA DgAoXDlNFD4TRZVegQeGKL4G8jr2Xx4/P3iBSyJEs3d89OX+12eejRHAsSHX3c+OESmfASAHBA9AgBjCNXu++3L38/0ziypwTE8u
# DATA Pa76Zyf7ewf4AZ4DLcLiHzKajs5grris8IN04u/C+mIPSJi8ht4r2ARIfEeKaGBs/M0GtmzGXiZI//D4DKnPe757vusTxPD3s31s
# DATA fbp/BIii/bW7t/fqFPYatsA3AJqzV7D7Do54NXC+tL0PTp97aoMRzb7YPTh8dZonOhz5GFCIXRLxWSvBLc4qVQ8X3z94AUPtfSHL
# DATA 5jvb+Gv/C1iKz/ah2e7zLw9oK8o4AOSB4ARmRz0IHpHyejU2IPHyD019Z0tHlIzUihxWp09CYbORQ8LmyIYu3MJ52uKEGMSi/YxS
# DATA LGjBh5e4qrLkxgvn5QNynGDuoXIY37IVtCBzj4wb1o6lp+BWHR7COqWjlM/84uGmN3QbROah33SQpSOskkBFo1n5QJU7uUlGFuwF
# DATA fjnH7FXJyM6ZMHMYxUWEOdae5QqR6ZQIrOoAYt4tbAvkR8tZeIPiF3wt1S5hgDP/ztWpg69Rih2BOir9Zzr8KFcTyc2RU/sOBq6k
# DATA TTdOSXhNgLyiQ6sZiOJUgneLLHdIuCphtWzOxaQww/OawjE6U1hCqsncc6+kZSUnVveS88UY1rXL1u3TOjiZmbMI55JKWMWM+0B8
# DATA yUYvVafitF6vUkcPyCTKgiFODOHVb4/1xaJzOYJDGWfW6Qu+dAbjlaoG++jOI2VKnOFW8Ue33jL1RF1k1+QMIqVaFdEjG2ctNFdX
# DATA jtiIxSsPpyn5NthJpQoeDRe6qC3OZojaJuDkh4hIeleVy7PmXsroJJl0O5gl8RADb4GuHSWxldqPchfN/xCL+/3I939Ir6fqFOaP
# DATA 0MRLMtU9wWEv8La+ZdpZ1mTuO7cye8m8OPj8FE03yJ6uiFeVSbJk8Jt8m5lXdo8KV5YtlNryvM309E1b1xiIUoe0lNkJ2wdWjs11
# DATA pWgh/1fK1jP7fmLuRznJDbsZenl9CXC5Sl3yjbp0FsdPM37kDnu6Nx1NXZUVaFOuTm93Ey0f7dtz6r8ZLLIxBxSNWTGx/8Pr+Xya
# DATA bW9s3N7e1q4mi1o6u9pQmUAbP6IjfBkZAk4FGqz1wtyRgiR8LTkV7EeX8CydYEkvvOAkmGJSE8xN52dY9RjDwFy0yJDybccPuCk9
# DATA fafjnUEUl/J2r5tP5ko6sgzRpWP4Vm/OzlQV74u94DOb8qCPeKBCHUzleMeMudeJXdWqQnHgr6mrvMhlxufk4iDKNAwcYwQmfhN7
# DATA OgoW6QRxvoKHC8rfZZY3XMp7SoE5uulJm3IkeUnBUDthEM/nkvVkzuuqC5ieEQ3o4wctZVjqAGu+yNzXOaQjGglTMSAuvcPMEvFk
# DATA m5sS1P1+8axCWXVo+8HW5OvXKAKJ1aC4GprihkYXWjPpFNbV7taNIC90boNLn0j0zvWSrMngD2Jx6n1EN0ADJrxHd8P3/vDvf5J/
# DATA YIMc7O3XxtHvcYw6/Ou22/QX/uX/Ntqthvosv/ea7d73/Pp3gYAFKlcw5L/T9f++vzt3Lk/XR7E87zQeTwKMBckJbT7qzEVE2R06
# DATA Sudz4L2YzT2JR3IOLEI5Tdlu5AOnXm5Ju5xEUuOKeMl6q1ZfxzDmM3PWRWnJfGkulZxgFUau7JCbLWsUuPjJjMXVa105C0XVYiqp
# DATA ai9hiGatrr19ckoN++f3YWxUTUEZnNNlQKaP9HYClvne/hEqKp+BwoY52OkoPD3fU+o3oUSVuQ/vTEk+BTQH0QBmk9Py1fmLk8Nn
# DATA EgShrEiQ/IC4jYm6A/NqJq7kc0xCWeckFD0Kmm10k4S6moru8kFMq0UD2fNKzZ8B3fYVs74CzWExqAESN2ZqTTYGQfgaOq8+3AoW
# DATA EhN6H2s2ocKiBU1+cn54toHLtY7okFgMnu+hWzHJuYsl+Jls5NDNgyPZ767Tu+XNWr1WryhUKwKrgX2VGfqiRd3bt8ovOCTHNBCj
# DATA 6fLvZP/jvZSYQFULf5r92/D/Zr3T67n8v1FvNjt/4P/fxb+Nj/3TBZUEVMXNwarkFApiTWDvUS3ZY76AUtf/uA7AxM2w6C/6rkI8
# DATA 3kUHDIC1frzhldAvw+eySs8oIXnuDzN/R+nJ5RKyiu1hVqqox+HsbgraZ74J/2yavfVPZkk2DvZGXJ+Fv/n39osbYCpvgBpL/KgP
# DATA Vj0Wztv44yk13QjpTdNjNIB3y+WKv/Mj/63nwz9M7uVP+I9byQ3p0PSIIndlHvjTGvcqYedPa9z7pzUwb5J5uVQrVS7ql/6nn/r1
# DATA iv+jHb/nf2p1jf+CKJiC5bFNbrDyE+cgL61Pr0qVGkNyclUpuz0L8OI6PJtj2to2pQiDTVCLJzc19DB/tnu23391eojFMd5s+83q
# DATA A32cg6WRLuYv8dK+bNtv1PuwXcHQAPGYe9TiR05f91VYPTBr4nHAs4VRy6vAqdSyGK2+kwANsBoYUOUSv1uqIDpL7O4r+fcVM8q9
# DATA v03sn25if6Z/FofmhNyQhnjKsqYVbnkPdvYclAyDRDSrb+m1/dksnZVLz4VZyqm8kSqRi9UY8FpG2jp3vj2Pkurdu6+UkeaoQPLe
# DATA dRy+pk4lXznjIfy3997GBisnSmRxADzyz/700FTmA+OeCkwEnEtKR0Eox5kr5ejaJtCZCrGy2gIvpTPQn46p4B45MMGcx1rGCV6E
# DATA Q6WdeW+TQDT15Z9hX3g6JsL7a325UssfJ6KycKYVp0GDXS5X2+hCKTXZbWaYl+pN3FSM9FKz3uzWtxqNZr0F5NOPZ0E/GKFd39c5
# DATA lX0qJV/attZJYCGkZovxtl9qbNVbUTDYbAbD1rDZ6DZbzXq7tdnp1XutTr252R32eo3GZrjZDQebg1a02YjrYXOrE2xFQVzvDUqG
# DATA ptTJWdU7EPeFQ9aldhj1msNoGPeiuFOH14NOtBV3wzBoNDeb4WazuzkMg+4g6G312pthfQAQdVr1eKvXCqNO1Cu526QUDoNOpxd2
# DATA B4OtYdyOhuHWVjMKWlFvs9FoDBu9oLEVdRvRsIWTaQ43W61Orwmz2Rw2g2YQdKz+LvnjfdW7V+wu41vbd/BowiJGpvcnZ8dHtYzY
# DATA A1BvmX6v+uV+1b8hpji/m8ZYNsPf2dnxSwMky3kJ+NhNbZ4yVwHmuQ2N1RBIP/YAzMNrIXnvv4CHsJWvg2anC8yL672WGSoeu1Kp
# DATA RclVnMGOv47f4AZS5ZnVvXtxdBiDFpgpWKfBHAe8uKyqADpQ1H1FSCQZ+tzQ/6M/0pNh2HBCXE23hA8/2p2BjlpLMvor0NAD6YBK
# DATA WkxC7AF4gTz7bIH+IniLP6hJOASKQF3kEI1QVy4B1GtCicBRMXwLPTplRikWL8W0YGpTw5LcephCnFxAE8DGRa1Ww2GqPn9nQDTD
# DATA i0dZ/CTgeCx+Tbgpv/bMu7dWZwSqgcKawb2D8o8Q5TxMyf/Lv/Q/op9rFOHIvgJVv1x6A9u+sV2CqclQ1IQHZ2wM7rB8zo4vmEdz
# DATA oSz9oCFU7oIZUEJG3W0rfBo07uTocRyEmh6rjnjcPTnpn+3vne6fazol4NahG5zA+k2jpGnVGSdMpujYzw31PObfk5tyKYizdRhx
# DATA /Socl2h1qjyrGlg2AVEfCNZGs6K6pRdBJs53wWo5D67KudaNZtVvblbcNRL8YPpXMC9fSCcylVwH+HJVjUPFisqVy4rZ4qXFfLiJ
# DATA 2Lz3guxuEuqa6X42CabZdTovK1apFp9xQTsbVwssN4zoDGo/+ItFPLs7DW5fTTDsVV472z/c3zvnln0K6rw4PX5peyr7LPtr0tlX
# DATA lNXC7fnJjlII1pyF4CKJOyTEz0CH4Pdr42BanhNvq5lBFfKsbTfFu8yBdi8uSkE0TiawVEQBff6GO6ykjdI+rA7m0GW6VcGjy0ub
# DATA MeD2IBBrsM3KOBpoi8RVcr82LisVSx8x+kO5BJAOR3KJMcawwztBuVE9DD7QYWDkLf4jNzvItFISIdywkLN5f7Hgb/gQIcHP81n6
# DATA 02DSVyWV8acbDD3rxvBRP7w0MohQhQMUdape6CObwR9m6Si238bZJVd92JZULg4UxwWeUV7GrDzhGdskYEkE++dkMsBIHGwlmz6W
# DATA SeAiDCYYp6E7QpJ4FGWXFieO8VwzMF3Cq8Pz+W1ZkB1f98JCh+kHhKhNTiBE+WvJ/8S88CzXpZLfhkJ0U9CMrYG2rSYMBz4XiBhd
# DATA zxxK/Ii6hknQtxzERCelVURIiXFYO5FbPdOZw8+E/Az85nTMAyyhJCwhxIsaJw/zBG5TyBR+0KBsBbPHd37Q9I9PMXvlMwxTRsjn
# DATA +tM0o/Q9IkjmIlV+p5JHvhprR+uFn9YMhVx+qoEB0cbUgp/0lInxhKQT1aypVYDh4rVh/Ogj2CrEoqN+MEeYWHrQt8uaKlJQDisV
# DATA d/lk6Bqm80tPZmD6McAfA3tkWlvo6bF11UqGYADtC4dKlzCVRLi+7vjLMxfaQs6AxMmfcB/An3yPGQVNY+wX9Rq1ZS+wXiF8l+lf
# DATA Vi7zL8LEHpQ//0GI7Qdv1RBmnUprpU/CT+C/ldpPU9BuStVS5Z5Jce0Hb4lI7tf+w9LsxYRCpqPYxmd3B5HFhXJsBpEPbAVBreQ8
# DATA BAWbMccVS/lX9I52FVrovcavfloT/gejoRZmnugHNbD6rkAJXEEZMjZV85mkip1mtv5aME1pJlPND1k0DT0VaQQC+wpBtvg3cTjr
# DATA 8aPUjEHeBUeoYw0SvFgEPI1vjRVEkTPW8hv33upvFipkI6F2USRbHWlasTY4pWiltxX8zwX/hHo6K9/WbznImCIvRJvDdkl0aTT8
# DATA Zcqnri4ruW4MLRd1JVIRFfJ9JRmXOr4IC3xMLn0XKE6oFDFI1ASlF/rS0OWTt4AEcmcQZyL3ecvMcHDcocJJqtrJyZPetiZ/77Le
# DATA QmFQcdQIUvHZVihSIFQP1vs1Hr5SxA9kNdGqI5OKOy7aP0JslLeG/Eevhy1yiredeD5H0QuWZEbo2VAyUmDmCAwi4PLZ6k2sO9PG
# DATA HZ7LLX5BGuQQZXpgmVK+YAOX7L9LclgYS9OiVg0d/AffuCzauQW/0cZj7D3OEUVGYlBFozwvKeFzaZt/km5FsPil/Ga7z1HsfbEB
# DATA nrPHMERbtg1wZdMGs6ubiybvH4A2BrPh6npeWtZax7Zr7lEdTbcmiQ42pHjKcN9MKBOujyU/uJJVHwOO8F1EaJ8d2n0z4lppWZga
# DATA 1yQ6eQrlZ4JXEWJ5Kt1R0bbBVjUXkIpRVb1l4mcdhXqvufN8ttT5Rxt/fhGs/2x3/c/q61v9y09+sFHDZFUy8FjKUjcWUlZREh5e
# DATA xAyrueVfzcsmM+IQhrt8223fqwFpGLUKldWD8I0txoMbGgcqUCeBXYQT8baZEIUEJQzqN9T7SOvm91r2F6NSUY/KnzPMavEbWOzs
# DATA DAiaXVDA4+FXLNvzArQN6/e8AWPZXEPoirr8dMl9AT1RTfPyxjezbyYbV7DpvllCrWKZ4vBVvQEoF/ShCkPg/6zOpKsZdnbJoo5L
# DATA YD3R/ymtc55PnOXFZcG6a9iMOZBf9FWSACvxTIyoBkFyfDspF7nlq0wCMO2ipxf48LJwGTSYPBZSfgHA9LCW893zPuFHS573D5ms
# DATA G7+x6X4xYbDsGyM0iRrS9z8p7JM89M98xAcaQ86OcaBC0n+mwyRuw7JGx0XjEmdcIlVa1NMlMbCsRpJCpxelNl0ATRXs1/sCjYfZ
# DATA ufbZ5WxIq1Ml7JT0yOZRupjXsDA+8P4vkXfQ4WqLOy+zkownbHVrhB1iyN18xUPpqJsWWXSvVxyZl8WVvVLYqek6sq5wNAlE5LGU
# DATA A/ax8TgQWCBZdR3WHQ67TINZFpfzHK6OXjLiVxZyciBpZ+tj6DvRagk5Z6pyoSe5nDBNHAOIfFU02ZKUGqO0bp0MsDR13ls5UaKv
# DATA smM/MSsiNQqrlmOKb6KuSahIR3GNfpIHVmTFCo5+6pvVJ5KSUCtTFb1ZG2OG61WMToMVbSUsqyOqxq9ftUiWafROHRvWPlVxGWOJ
# DATA FivNAavRYFmaGjq7dNDgTTLfw1SuHb/xDLTJmhT9l+wC1KEwY5fj6WVc3H/7/J8YE5IxdtwfBXdINtO77zb/p93sNDq5/J9mo976
# DATA Q/7Pd5L/+dHGIpttDJLJRjy58ad38+t00vLW1tZe8o10PpejNXTCJ/Ezy6AhhVAdFCGjBvfN8zR8jbWTYE/WoDtPlRGdXRHTU98x
# DATA mV19Hk7GyCvU159meIs2f04zLmmCY42SgSpKegJfVZOZ7jO7y9RHrLygPqNz0fPgIcVEQZsAfjhHZgtcsIw9lft95IH9PuqJdLU2
# DATA sC+AFjWzih4G7/wYS4UVOw/RGDG+ntt4HGDWJCWuZnEfmZPneVGMdXSn0zhSEWywajGX6rayray2JFMsUbUBKOWxZQUi6PgesEMO
# DATA /ILYLuOP0GOlsn2JXalgt69+p6tFrbgrrp1+iXR2EF3E5qnVapBGwDOXYbqQuaE+ZE2Nr0hHOy2RmO7l6p6xItVyz29Bdm37D3RP
# DATA XhZnjBp+y8oVx3bmafFCqLVBmsjK7JFcWhAdREJyrUVxPMUP0rqiY0bqDrREmeeSuMQ/Y2DwLUgFGh1AMtOTBhcl2INEgiV0RMk8
# DATA Cx7a0wb0mSdUQESAoAW8uHSs5Rt0bcVWKwaQf0b4Li4tsApWhxrK8pCo5F+4G4z0A+VwmsgkKm0vKa3c+qLE2Uj2LPNPrCk6MyDd
# DATA HOAvixOcoq1ZDKJ5npVysH/fPxNc0A32WOVLzhxyskXGBYExo4gYS/ZMMqujOBwFM6uMwyAepbe1JVeuygpxsMlekCVEPkzqhMuS
# DATA XkN6tF1ogfA2L+WpxPk5j7whlZdOF9OnYM6ZmEXG1MEqCv7XmN23nZkhanvTGZouhvgxwi5FMS4pA2wReYQ56rN+Op1L3+5EFB3b
# DATA zS4vVGcFBL+iYX6ijtdPWBfo3SCaQGlV80rISytipwydkQzGzkpTWu71ddBH+cNfLJIYDCLJVK0oVkwZfFG2zNQvbTBQNNdGaRAh
# DATA xywYDfCKRxNgpI+hMxCeDLDehlGZvbaST0x2CecKYlAL9+bOUTqJZVpDKYZPLeVEvLxm4BwFsEl5+vKQ12uPiF3IgH45pJYlEoNv
# DATA 722CcEHg4zDUmF+EqdZ4kjWRGjVpylzPfX0771QiL6Ox1pDhoEPzaSPU8KQg6FX9KJnhApYqy1EU/+Mn9iXxQw4eUmcqYbla3O/F
# DATA GIsec798YJNfk6O5Cyp2nsf8S/xdhMrlpY3nYCLZdUorYZ/eKrWEn4pe4rAnQmJuBwqJns8E2fL9BVhtSuajKd1XUrmMWllV32rK
# DATA icw7jc269BuBaU4HhXa4jtc4hT2Cqm8ZYZL21PL2ms7k5xv9UHdhcR9npzIEq/YobCICzt2rRFRUMxT1kg/dkMT+AIa8kgA/owYp
# DATA HRNV43cen4/NjEblUCgBKw3YO+t0MZmQB4ut6BWtvoiD0fza/gWbLHBHong6ost9StfU6k5WPCT6EqgK11se5snsWwBBKQkTNf5j
# DATA ww9mcfDa5Izj4mcjUBDLTWHcAZaF/RIpVtwle7tHx0cHe7uH/cPdr49fnfePjs/7p/u7z78uKUYpB577iwkWzSrP0nReNcffbL5p
# DATA sUiyw1AZAdtDXqpdjdJBWb+Ie2j941LFFYN8F1QNaziQ/VWGL3EWBtPYvImkPiutfxO9bbTv4c8nJU67rbGPWEavJVk/uxvjUe5y
# DATA hS/gnOsHwLj4xwekQOURpil4wdMeMDt/A9M8w9eLabYBVIDXnKyzF6MEjzR4+bfFpKuNXyNI4zSKd+ppD08y8INsB3kHCiQwb/rp
# DATA a/pacQhLOuJoRV4PMkCqdsjJKGpUVr+o6Mg6OrLQMK3hf9pgb17Hby62N63wNc0D4LJez5OJKHRCJ1QAxMaqLUvBFN8V+NgPLglh
# DATA qs403bxCN8eYQslUEwWMvRtLkSabnugbF4LXw1jNkminyG6HYdJyiX8m/TN/kK+kNRHzOp8qAMWVjiTha3gqZsXrluaytPMOjr7c
# DATA PTx43t87fnlyfLR/dC6jWd6NHfIplAle4KB0kzNoWKVLDZdpXEju7mMi+odAenV0tvtiv/98/+Tw+OuXK0Cy+syhGGuVRgGHzyiu
# DATA XcQJbJBgZQkmlAAF9kXZZQQl0Ry+qc3UYWDkAZv35/Df7v2fISf4pobCx+EHRYaLYhGS9uWX9oIoukMVpDaga/7W6f7O9ZvppFTU
# DATA gb5kconPcAUN/hX7K1cubW3W4GhJqcV94VnCgnrBpYd9CFs/S34W+z/yN/2P/Ua92VZ/bAybzh9c5cP9z3f3vga6O3px8Hn//PgY
# DATA WP/p5/sltVHUTsVYs1HqeRfoZ0lGALPMNr+LknOFd37MOD2OqPdSCwagYbzp2RBEWXFPfg3Iu1KbkagofcyrmRMR3IOD9pwQXkXY
# DATA p/ufH5ydn35tramBtYamEKgq4lMjBabMY1W4fcDnmzFvRSk+thvJdOXar+i0JEtBvEQUmmNfjMUxXprgOtsCuUk5qiZ1aXGwLH4h
# DATA 6nOhqc+AU7oY+xbpfZejwArwaQmzq3mK3/f3eAhzJ1UyEVToQM08TWv+LjPuiGs5YaWYbC4lTYKJ9KW8Q1UfvTKsrlcls5ov8EIf
# DATA AFc/ta54yuYpGqrat+GZfGxLdbVdm8w1K6S6CpjIpD+mJFZlhsGzSbpOBWGmeGVurH8DONcJEQuVjbu+ztm++JnJkoDQ1a7yiq/x
# DATA xlkOH2kTLcbTrKxfBfE+wTI4/SALk2SHrAN+lT1QfWWfvaXVk1MtsBWsr7gfVBm3snhMLb69YblPi3IijfcoJxwd0rpfAkolDThD
# DATA EVt1HWSawZLEvEomb8jwK1UqBSqj6d7Z+C5fXc2ElzxBT2Kly9tmmY+cHb863dtfxToNT9Hr/ckOhWpBrxLNKYj68/jNvAyPU9Rn
# DATA djC4ur4pPUzxgvQZpTpdzNPXsZSNpU/EYTCKF6HVMyuVShd//k22Vnp7/6x6+Ql8rVoDsyv2Y3IY8evQT+nT3PcL850ZNG1HGv0h
# DATA G3uF++PJ9jfCZvV/jp7aqrhpLY+tAxIg8sL2fGV5oCx3t95XD3q8vaJd8ASX9O/khb4UfUoQIFbHKocnz32JnJHoV7gtl4wUs1/x
# DATA ZPkyQ6jklDhrGPXaDu/MdKbLjbCvQ0yXrGDj5LweS56PJ6iL1mO1gzWkSglnKfSAfvaQdacbOSuxojOjLcrQZqs9MDyqcRJHrMnf
# DATA EEWTOSqKu72i5o1fBLnEBVYm/RSQSllDCFuitqE5Dv+iHVeVD1dHeZXFqrKY9UzsIDF6S5ZPwKJn/bZ82KA3Xa4+KzJfyvK7Mmst
# DATA dj+z7Zmn6n6f7e79+NVJ/2T3/ItSJQdegfW9wt6W9uE1tC1TU1ENtZmt51kusTW7zqpAoXHtvLwEhYjGhI8sXrwt0Um1bXthVfLe
# DATA tgoF1yhozL/ykuddqCUcQPVihCL+6v+RDwP3evcrdqK43WUkzulRMwcFHnSwBCuHKhvsraVgbhMNGv6Dihm7fLd5hvcVYfc3bDZc
# DATA qvIXLm/kbRzTpXcA28+SadnAV+WuVigAeQpbiTH/ox0e4UKh9/IpyoFoBVh98vP95/3nr04Pjj7v757ufXHwZV5FKPCj2F4itzHh
# DATA RJknhkuxh9//DDjKviptsIwsZlZYnhNYHPVUKRQoNHbBZntQtyIrvQh+NTeXpxLOmKlgxlK59O7/ff83737x/q/e/+27X/rv/vnd
# DATA b9799t2v3v2KP/76/X+EL//1/c/f/xW0+d/4wW/f/RK+/vLdr+HvX+Pf93/LCVhIXsoj5USpVL1GibCP4mCymPaNsZZ3aDrBnqW8
# DATA CvTrZL7O8kDrkPk06c2ZoVxX/XWdRQ5/pATmJRsYGYjyy9Usc2MVQX97C3hJsXa74nkVGscsUezZo5b29uOP2c61nGvbRd6x+5z1
# DATA TLik1TBK2uWDPgkeOo4nSzY51x1W5oxrRlgWzmJCehzm4LPZbbmnKfeQPW9mInjCpVDOFSpfmv35Oyavp8Cblze5lXNPv04KaTx5
# DATA mkP6MQ9sxUr1iCfkFdAjKWfuBE3dEdhJ+d1hkoIedYl+K+/nag+uOI5W7BUnrGBvGKaEHb/IreMtU4RZ6oqz1L4iqgLCeWieen4U
# DATA WDk4OjvfPTzcfy7AUVh9jjdgPeTsraopa2ge3xUwK+gclXfufvvbU8kHxH+WM8KgVwseMRkQszQl9I6NokLX9bcJAmFfJH7MbL/v
# DATA 77/B05XJnKobzSbBaEOqIRplhPNq6HKcZMSXurDM/fZIK0IADiDT1fEnXp0lDGAzo5tF8Y1CmfvrE5z5JsBnqb6Jk/5AVGhnPwgN
# DATA qnyCS2aNAqqjI1i98GMHGw+7oTne+PwAr/44Pv0aNkf/1dm+gbBoPLpbXKPs0YCGmfw5+ml4E+oRldNFMixAdoVWgNXydeOxu6cl
# DATA cFSelpyRRzCLucGdygNAV9/vPqR0BgzKtyYmg97bVKlQgLeQxpOyfCUOiN8NYDQmmrXLW7R0sbv+Z8H6z/AEmPnYr61fvq1XG83e
# DATA fakq+W4z7bRRCpI1wFOExsnp8Z/AEgLF4D0wZiUp337HL3AD82MK7RQnKEjWw+/NV+zkNKGuYuP0h6y+MHxFTqtHonas1eGlLBo1
# DATA fM+O2k0cRN3J5ZfyeFVbCnFzKflgpX0yo1vV8MJ1FV9y2GcmLAFlNVPmuqJMYHUl0e3yXeBZ7bsTvNeB+lkxwkVd26KY5IEDOk7n
# DATA KtO6QbJKvSXN5bGMkUvRHDjmkO/b7ZjW1HYMcSeyo8k3spwhUGL/AKUHkGPAzYpY7Srg9x/JFqgUmOkCiaU2SaRTGevWPln1plo9
# DATA 90X+9vCbWBzQeAXQqhKHACZ5Yz2fVL4LcWHxHVmMbYVRdHbwilBb+iROA3WahotceMUxjTwJLdtgAry9SVg2sqfUM9FjGe5C+dXw
# DATA 6GCAvsj+POVsd6Tdcs7nX6k+5HRR0bbn8TCge9fAZh/hNQK6mCH+MlOlUfEooTn2wA4Rug6lthRQURObxIv5LBj11QRVfxnP8oL0
# DATA z6m4I1fizQ4w/j4xsYqWyMWTo0ENR8UKQM/u+prjW1ShsPKEuPP278nklnRDf9ma1k0mgKa+aldwPsPmwkqymFc+2ikKEOTQUrxm
# DATA ZH/TopmAoXLKWc57KQMkVrtxe4iiDOusrBqLC8gxwXVj3Cw7+XICGTc6S1RJbsQvrTrmDloS1EZDTm10USAPXc+bAtba4aB+S5v8
# DATA I4ULJ7hhiwZNi9tLHj9fWWMSIy10UxYDrp2GiwlTn1EInH3yoMitsiJgU9ltv0hpEqlbWVoV9cKjqpJkdLt+F+LZeSfGUseLqdas
# DATA wETL9JfBIhlF/G264KxUqvisG1CmLlKGjOSMLlLkqaNHWo0LY1DumN4/GK6PZVTXn2syZd3cXwNF4WvLoVfuZ5lQpFJEWbe+UFbE
# DATA ZaEFcfGQ9XDpLWdPyeHVHUsP4jP4RadMJM9nJTD7kxuGBIOrwLmkvRrlweY2Si5KB1gfnH105m35sfgAS6EXny4wPO3TzYsH518r
# DATA j35BJhjwib4Eh30NeFmye44wWgOSTr4+j/FWY0nxkWR1m1+siJNbMXKOI/N4BcAg+fyuwDwWtX86NOzw0QB9tGPD99TFeH6892NY
# DATA iS+PD1+93H/Kgihl3NjYePD7TJFy8biWjSGzJ9PDJqyo5J5dUxKzap9OcqSrMjgKpYCoHqoXz13GD5P82p/DfdnnFbRqs3xHRbZR
# DATA KpAwj8Q7EjpxPr8rID2AWeZGUsokGat3ymZelaKgRrE40x1XLbwUL7sG4SOGoXitc4qLimvotwvTRVdIXgrCgUa0/cgkVsPvtmOY
# DATA qv6S9HWaydl4JaMdmf5wSJDSbm7yEtjRvvKCsVAr+HC1jOPYVH9g+6F6a/6D6kvRsuuXH9CbnEGKl9FW4qp+GY2UKpZkiSuOSle8
# DATA qR/RxLhPq8ull12tFK2mggR/paU+nOivW61QX38X5pWjVpeHLVnJTgqBu+u2fw+Kr9o8lh/jKXrnss6ptMgP1PQ+WOf87vTNohNm
# DATA Sw1NbN6op/mgUnEURDMidSbJe1LUyG4s0RLpyfPwpsE+yY9+n9SMfh/leL8vx7ipasOMDrVwBYfa7uxqgaGcE3pSjmItwnb6feAl
# DATA /X7FehODnv1AXikDIhE8LLQLis3OCbFruf0ksjxqK961z5CE1ykieefiKcdDLh/uljMV1k1+VUA19XZKVPCpj8UKlXt3RoWjpSP6
# DATA g12pJEeHwxNDucpqKhFCus/R6HKWBL3Eq8jv60Cct1oW6lIFJp78hH7sBJH/590v3v39u9+8/9/f/erdf8O8kF9gxsi7//7uN+/+
# DATA Kyd+SNnM5eMxIgzLRqGs+sdn8uHH8R19WvKsn93BhMf7b/AA6rv/791vYey/ev937/5RYPgHGPzX8PeX/vv/CB//G0HyDz7mo/jv
# DATA /gl++QdMUHn/f1CKym9q/rv/+/1fYQv69T8D7NDst/AT9QRff/3+b3Fe/z9lufwaZ/bMf/er93+NA7/77+//87t/ev9z6OtfKENG
# DATA Dfn+b2VATJ35T9TXr+DTz9//n+//5v1fv/+7GtDF/4T1X67j0ZRE/mSO18uShvgd3//YbTW7ufo/jV678Yf6P9/FPyxQtkaebEnH
# DATA W9v215rdXhhsNodRqzfcajdbrc1uMxq0m71WEAfRoLcVwffNsNsaBlHYbEdbre5Wu9GJoq1GFDcbW2uY/7hGTuM1dVHPmtynuGZu
# DATA 7lmjaorwAwzQ21Q5k2sGjnZvq9EbRkANwSAK6mE07LaiQVzf6gXdYbMBb22FnU5rqxMN6712b9CKe/W40Y0HQasLoHXW1O031K++
# DATA 6rQIhN5WqwCAbhw3glYQxOEg2hz0BptBtNmLo0G32dwKG93OoBFF7aDR6DYaDSxlFUTNditoD8N62N2MNiMXAPuuvSIYNju9TgEQ
# DATA cW/Qa7eDJoyy2RtsxcNO0O2GW0EzbrVDmHDUbnZag+FgGAXh5tZmPQq2ws3W1lbQHrTaja1BDoiCgl9FwDR6sAeLUBJtduqNuNsc
# DATA DGFRWr32oBt1426r0261h3jJUlQPhvUm4Ky11QBENIeAqzhqNFqtXjwMQxcaZj/9AV2xuQqSRqeQOrZaQBlb9VY7BnIMOp1Br96O
# DATA NhstQFOzGzTC5mZr2Gt2NwfdbhC1OjFgpt3sArX2eo2tMGq5kNA9d30RwisgaW91ilBS7zRaMPtmvbkZbG2GQStsBN243W10e7Ak
# DATA nWG8tdXuAn6agyaAGrbjQT0Ku/FWvQ3LBXRVAEi2AoKtbiGJRGFcDwfNrc4wHAZhazPohPXNLtBCb3NQr/e6g0YjHgzDDmzbej3Y
# DATA rG8CqYb1Xm8w6PW2OmFuo4CqDCDQcdFiKGCu3V4BGJ1m1AmHLaC84Vav044GwDdava12FDY2u53mMIw7W4PWJqxPD0g2aMQAbDes
# DATA R00g32anU8+DMfvZIJisoop2o90sgAFAGLYGg0HQ7UDX9S3A/rDZ7sHgjfqw3R5udsK4F/Tqva2t4XA42Aq2mlu9zfZmC1as3uw2
# DATA XRjo9r0haDm3YEevwka92agXQDKIGuEWLHNvsxNHnaCz1dva7G62Bpsw7GYIf4B8GyHQyGYw7MEGCuNWo94IIyBXkICdrQJIMrC6
# DATA VkHRKt6vA5j05mYASwb03wu7MOte3K0POq1mK96C31udzQGw0GZjAAgNNwNYtk6n3WmG7Qj2Vm8FFP0QmNkovVoBDVDaViGlNrqD
# DATA 4daw04nrQRQPAO+9zc0B8M2oFdaD7qC9FTc6HeAhg6gOpLoVb3Z77Xo36AwGjTCIGzkSIYW/L0mZyfxu1b5td4oYSLQVNYAxhA34
# DATA H+zPNmzNdtxpB8O42+nVOzEIswgoudGJe1EYRc3GZrzVrjc2W71mI96KcrAo07gYhM1ms1G0ZZrAGpqDrS3gVjFIkBjvfAO+HnQ3
# DATA 48bWVjTsDbpBO270otYQVqoOzH8rbPWA7W9t0pVwLgxcvbRP8nwVLhpFVAK7od0BNrYVhp1WDGQLrL1RjzcbQDytersdDjoh6ALN
# DATA bmdYj5v1zWFrMwa+3gp7eBNdnpfaZtcqYdeG1S1k6k0UsjEMHAbdVhg0W0Cz7SgAVtnrRvFWB/ZtF+R7u9sOtlog7LrA+eJmFMFL
# DATA YaOzGpC+ucdyBWqAKRSR7Fa9EdTjYHOzEQza7UZzE7htI+o04IetziBsAEaARAebwF8aoDeFw3o37IIK0gT+jlT8AEhRiib2Kl4P
# DATA W7RoB7W36h1ARzwIgX67EYjhZiMYtoCRhLCJu4C2rW69C9CBpO42gPEh1HG70WvWYR89sFSmgOEqntvc3GoXgRSA3GmCGj8Me23Y
# DATA Ju0ObI92F+86BNyBfAYeFGzBggEVgyrVa7aCYQAyBOYQ9Brdh0CaPiAMW51GvWhfbwJdtlutEFh90GnXYT3qnSFIuhbuZdAlohiV
# DATA gLgFOixoDK0WqEmDemczBC0F3mo2XHDmo5XCuL3ZLWIrja0eEAXIW5Ctg0azA2QThmEL0ABiqVcPh5ugQQKBDNtRMw5g80fQEvZ8
# DATA OOjWe60cvSyGt/2rRTCLVnFaIIciNW0I8hXV904ImyhoDGF+EWiy3UbYAEVpOIS12oyAl8RN0NxB7AAL6gDGGrCvOvW8TsJOonVY
# DATA i9U6QQc08CLlaCsMBq2oA2OFQCZRI+gAx2gOO82tAJhHqxsAVpoDIJw6KAYtoOAYVLVe1AAhCSulGJwnwKzxzU5IjPT1hi/eJSqs
# DATA NWsNFOD33vf+8O+D7H+jgP8b3P/dBe0sb/+DKvIH+//ftv7vZ1grIpj46tDFTBLepPwvlg5KxuMFaRxVPx0OqUYa05MfpniP4EN1
# DATA f/l6TvUtns0mqfpy9bNkqj7jRTejZKC+JunvXhz4ejFPRro+cDBDP4X+Go+n9ncuGYz5Cae7e+d460WRw6zkvTg+Pt8/xeSM0jeT
# DATA 7/un+y+PdvdenZ33v9g/PNk/Pet/2fgGmu0fPac23/fhU39Vq92jvS+OT+lGc3LV4gmx2WCt/Om48ufcsv/Zq6Pnh/v9sy92gc3u
# DATA lOxbQEo/WKt4Lw4O988wHaWU3+AlzvMUVRW/2W6JvNO86DdHTbAvLy4Ziw3f0YYs3R45Up9yskS3tGxv5cK3LS9noJyeuwTh1Bp5
# DATA tQ649FSrY4SWAkcJ/u5YxzQhS0LznZZLRomekBhwznfLlMLfxU+GH7XHqlTxXu7+pH+6+xWWlu+6RTToES44PGvmHuVOlkVlXGxV
# DATA 1xArc0dxCHCUnYoYEhmi5+qKkwFfblIlAtdl6uS2EqtTeVe2bU2O+FIDzKhWl+XK+yK9+69jddvytreyKF2Jak2p/5Q/3V63Tj/g
# DATA 94va+qX9U+XjyqclFSN98IyD3F8gzEug0sWZMF+/jzckxOo6D0nUxLDPnK6OLJfW1SEayr0YJnxEbL6YwubFGuMYWsEIr5RexHpE
# DATA SQbowHqOXDmm3OA6RRXvoeoD6uymgUaV7qyVdNfOOjIMeCdNwkfHZvYreOsv4nqQpqOy6RR+tWaiS2UDqdCmE3SyRNixCYwfq1Xk
# DATA HRpiSlOZeWTF/5HfeGgxnuub+WQ5hmk6j2fmjJLwWiw6MnHCbPS1Ku19OU8uU5XB82UPuW0tnkScvQNs+dEc4wNzO1MRhGqhSBwm
# DATA E3l4sb2Op3qw/0sGCZ8XlVBGsMr40M4qQpHxfPd81y9JBUV7Y+DDvd29L/Z9Ww7QBlHfW8172gvYb6XylJP1rybxmynfG+LM0per
# DATA isx64LxYZOlKOUwElFn44Fq/lAsZjY4hYwWTEBQIlx/xcs7w8vBpmdmQ/wnzI6FPBbFDo/J2DkKLlCsXdVmS8mCttFa5aFxqtkjF
# DATA oTS70wktDwwAAgW6KRbTawRvvQTcudvGzzBc1d5Vpk5yoKqnjIM3yXgx3lFM3nDIRwtu5o+WL+P/C8Y2nXbAimGYk7IYBTOq6WDO
# DATA +FuHzpEaeYB0CuteAuKr+EGGzeJgbMaiK/B25Gc6hVCWmUCfDYd2SDgAV5DnT4CXap3N09QfYaaNSyV5WaevW+A6GeVZYF2ygMPj
# DATA DzB6q9nrbj4FV9LR0vgyY+ucG/asjzvHIiZxT7wtsRVLd2iLsKliFX8ThivpWh33dF0pvHqh3rp8dF+9mmSL6ZSyUdWOUnCXKv/6
# DATA EpahUzO5/PaythgqR7tVoznI+qAhWWjRheNutRfumLHulOyxSk/RU1V5SvYbri0p3PpUIZdEUUc75RvS2MNg5uUKW1GliuemyikV
# DATA gE/lLKWNFSMRV8+cEF2/hDWGn6Z3fwkafuUvRen8S9Y4vwGVsyJHR58gDh3sIlBUM2dJ1lpY5GIVGomIMlJbZHPoHUDOJd4Bj9MF
# DATA 9mCqx3wo3Cpn1oUbk5PK3DHDgjnZmZw7nCu46v4PfacR0oFi2B8IBxbKM7shW4zd4R0dkAlA1e1AChMr4Ql8jGlrFRfFrWDJIq4U
# DATA LwllwNaqUpZMyiY6cvAtrv42izA6Pa+rM/FpHV3kjM6WywGet8Vmj1w2JmmPy1V67DNADofX2/heWRpyX11ZlESahF25SNi304uu
# DATA +MtWC0kKrFPkqhnEn7lFXkGg5kX86mE+4DpcEE8OQ/CjlIuo4T4oOSJGWM1HO1rgaEw8fJ55Wdvji8VXsB6n52UWpC+/tMUxteYj
# DATA K5WlevNy/yVC7tK7hdylNsWVolaTvLqacYz3lQLurItOVxC/vm5viWyAfZnzHDL1B4jMFI/WLxUk3y51gJvIegU2gfJFVVljqVTt
# DATA DWo1pdEr+eIYUgrRwLCi/pk50i0riXv0449l5gqGbRzjfnn59TlEF3Tn+J2kTHN6PS122aIVtdaVfHtVBa6LoIrWPx7EUZTT+i2l
# DATA Omc3ypnxnO2Yr8D3gBFZBf0VbATbohNjGAeNyMFX4nsu0dy66G1fFhiEjhFI22C1yecoR2oYUS7kKzL/7qriqquFjsJdgfT5WSIn
# DATA 8dlTWxt022IVyZBVTa5Wvi7ZB+jArX0O/8Hjy7Tv08FPd5K09hmu88FxmfuuFFoOQFI5w0G5vvKGg2juT5B5++40syWxp1RAObNM
# DATA sxDXMBs6BZPA4fl0wU5pts1mkGRgG1jGiGFyBamKg0DF8mN5iQ3KA9IVW49xtXOYA4iru/wiZjlHBHdKIpK7L3Q58DMwG6XSr36x
# DATA JqV7tZfRPFGil7GHNUY2Smacmq488s03+Z+f5oHAa8aXSFTwWMqfdEHhYo1waaE8fkO+epoZN6kwZakbOm772qzbEa1qmk7Lis9V
# DATA VnF3/ZrD5tVVTcvPtUo1ieJZkUwJAxBSdjW8x0RKuphPF3RuwBBm5REa5ncU6d6uoNxCGSAnHB8TBXmv1mSY8kEjAuY8mB3AL+Vl
# DATA fQ4bEr1V+SNCqD5ixMLfcbSFqg+CoN2GP0XHcjC7n5Yc36/aCHKli8W3Nafj38rEyNAqm8VZVma84QYmlRsrKhBUO3VdUVuEBgsK
# DATA XbUNF/Ux++xR1x318qFWDb3k5+wxAfMTjkSx55AKomDjmkxdub60iy3/pog4I6bwRl5G5UUC9P1mm/6LXLtev1TdsP1CD/AIVDC5
# DATA itE7bkuyKr7g1pO0pDl0pKDAIJrS07h+OUe5xE6h9vZeWuWt1o5qZdqZWxZ0wQrtodzQn2roQOACG6y/VDQ7odid2D/O26UCDU6R
# DATA Sc6A0e4U1Hd1T1/un54dHB+pgbmyR419ok9x9UmvUkiMoxnqtwKzQsvFnFFnWXMfZMK5mOC7g55ixD2FFdpuYvupIhG8WZsqbajz
# DATA TE4V0BUL7BAOkaEpq+Ks+neNKXI4CWJk/Z5KJra9q12RmFBjvJHbqtO8W3J7panr1jzWhYYFH29LSx1oJi623rbD2+8fFECO66ty
# DATA f29tvLJ12wNOskrvYIhR3euE7Gcy32nqS90Vz5NyyEsuALX+T3TxW+4C3bP29ls2CZ/atgwg69nDrKPivEZwqhshqbXaIuwvENnR
# DATA Z7bIUkz5bAyvEt/CCv6kyNsyNlXnGk1PMH/pRjYuczQrG6isO94ozvzNm3qdI12mzYo6QE8Ugeakmro4SffLJvADV3+JpgT2cacj
# DATA p/uUgWu6AcRZ6+49Vhhn6QS4aVwU0llZf/HJaLiKJ7G67MbL3bq67HPQB6kfdDeo8pOup0GdAdTn/uzDgAVnALkE1wmoWPHshgtt
# DATA RQFmhEQW0DVfKsX5lDiSwS69k6tuqB5mrjdJUsId9syXHAa6ggHgBV0XlmpIRTTnJofJkEitoHxRfq3Ltk/w4fpxou+tJoUYc40C
# DATA 4jBUDkwlISFl4mcMyw+TNzulmhh46xgFSWY71gaqrKas39GZo2uOGzhFHjlMSPHtp7ynnTjtttteNzXV/tWWe7B0Qprps/eqh+Ki
# DATA HUKbQppo98T4ofCmZnpSo8w05TR6S99q+/s/OTiDLSHfQITvvzw5//r+gRIrS0++7+9O6K4lK/iN1zdNF4NRkl3TNshQ1ps9oO4X
# DATA vU6ygu6mszQEKwUP41P5kDlsmXgBTIGv9PNVcEkldmDxB0nTK5r978KMHmZIQCnquHsBb+J6KIT7ogui/3VZVWF9DJy8psPVBRKc
# DATA Znk0mSdye4W5R+Ujm5NYvyvk6jeRnp3KMmb7Pxnn4kNR3j0gDWShkmlXUAmGkyNrs/F8FlubyfY1uKrHSk+GEAlteOd1x4NrpynR
# DATA CzpcD6Zl5fdSeCCdKlqzSwegdUD11DBGUKpqveuRggH5GgYPNiYsPbm1BH+f3Bxp6sPg4QVZbv5IaQNVzUAjkqpFEAINWZK1pesO
# DATA iBo9Kn6VcW696xjzS53YBQ+4ZIHSeqmppAlZBpquesD6Kn+xNGIGidXiyuOFMJg2/xc5Y5BPvf3u8/8bjU6zt5T/3+j+If//u/i3
# DATA trZ2GmOFKj9bTOnCmjiyKiNzDrfUsg7QKYAJoRE0DlHZGC5G9t20D6T7U7r+ByTpLwaiz+hf7vRH9Ll63un+yfHZwfnx6QFluvOB
# DATA JCkBg/6Gq+twVkvSjVE6n4NJv2EusNVlYpZ+yl/btLqP5coyTn8Fj/N9j1LQwIqgyj8ouMWFO+MyNw/PVVXCWf4lPwz9Dj3fe3zj
# DATA IiHVwuf1fD7Ntjc2rkAXWQzQK66HO81N4t6ZrAHzSV0wHPfewcvdz7H+YO4chPiRti/q61vB+pCTfyre8/3d54cHR5gDTzFcFWiZ
# DATA pllC1ZT0rQkm+6/0xyXnWrmlaLC57Frypf+4RMFfVQg932omzbZ1MwUG7LBg1MeS3GXeUphOns4p42L5phddwse614heQ3D5fSuc
# DATA oNO0MQqED7lg5EHENzXm4w4Kr1b0wXRBaqjVI99dwHA+chOOc+Nq2QLkFBbhPLjKTAXRT5aePydr2jTxlu9RtN544vUM6eyKAl/m
# DATA WokadyIXWVq1h2/Re3oBU5BibUP3vkEu9mjTEtWos1nQhV7EpYKs6GuXyxucLhzlnrcjz8Dc+Shb0eq8cmkvKACeL7Z8dUVF32Sk
# DATA hJ3SeeCtWdJBLt4M5p7F+5w/hWQEmg5olpLVhCPRlcHWrPxglKVM7WSBZuISg9+TIIuzWq7X3ZsU7MEge409P6fig+i54Q7w7Bm9
# DATA Bx35P8UMZf49wo7j0dDtrHgFC+fGCfQuPuRpAfYuC4prqQqW1sbB1Ho8CZOE8xqKOXQ345XPlYrtGRvp2J+irO0VN4AWrn3RrZ8r
# DATA 4bkwXy7daBq/pI7wENrLH6MSXCUx3WdVOJfbh1ov3/rQqiOcmuE6t5LrX9dJStfGKUwX4wRl6xIc1dUPd/x63pF7zqUtlcuAmJ5o
# DATA p6BpBBEl0YByD9p7ZO6SIcfHjqU11GaLSflCClpikT6c3mWVU8DEqRsG0zleAC3T5R8xUqI+Mig7Y1D3W/WqAbziZKGoEbN5BK0p
# DATA D6f99EQcoXpYElhjeIYOqjjK9JxHyTiZu7mZVoZ5fmwAyVpBXhK3jaz6APk+2EacO6pu3uP7tviSUSc0K804Mmumc5fEo4iPQuFt
# DATA BPDmNr/PMV8ZC2sR9llqKZM+ofL1QnolVWcx4MKKupC5kyKllppl0dLlc1ezdEH3J6iZwRD2lX/qRX13towNpiPmPeYvkHn7tka0
# DATA d4+JxR9T5y44zoro3t0LD8tW6UWu8SlldV/H8VSAw8sPgJmqfUO/WbpMfhMhZpv1JVw4KFbEaQ1p2daS0Ji5RxXI72y94MQNH8rk
# DATA 1v0xA3w0P+FE7iOwqqqrLpCTJOwjtG+Lza8cp36qsuN2OrSGZfUlvu490nYaOgrpItUID+qxPjUWLb9UsS5Q15wcAcB13X4U8igH
# DATA tiZFNYChSd27y5kp3a7ouGGBDFrqfVS821Sl0zlwzjC391yGZw1Jh/nQZn+Ixek8NTEmce6DdDEhS9PxREoDR+8t2NhmeEsL5sPG
# DATA eN8cCMIHUMqbeSU+lY6xIzlFQ0cfrjo64eSDFXvlN87v6h/t6E2/XVSS81TLTEERMB7cPNH2auHIntgdsJuR9cezmevtHUC71w+G
# DATA I10zoICLP3oJ+vd9Ld6G8D6ibB0jEmzLRPEoRpv2GfAUn4rwVhU7nAIRUuqg1K53db2l1Z2NqQ6vXppKTmfjJf1kx288LUhp6RFn
# DATA +mNR2FKWh9UUsyYy6zBdjPj6PHTCj+6UYpvMVy0O9zcs7eGiAshvBfZ72zujTWUhhme6ejDdmq4YbI5SSpVv41r/4CK8tkn0IQV9
# DATA WfZgXJOvYtpRluuK9shqrfK8rABbrysb8hFftpLUbllccQmru9roC8ns//Wcw7pIw+9xjEfqvzR7jZbr/633Or0/1H/9rvy/X0pU
# DATA VecDCueQi7zY6Sq2PyosYKEzg3vI35ur2/Kg+7fqn4AddgIm95sV3mDL9yv1Wuz6E3zQmdRWOcvFXoedfBkKKzGa710jTffhg8yU
# DATA mHS9mLwm39sceOIoGA+iYNs5omBZexWskZGP0DJEShGk/twjR/y8oEKGCnlzqGoeXAE/ysD2UcqPXN5M8zFRMiud3dLyqcGGKszC
# DATA l4EsK/ojWNzC9zR/XGcnxeourGxWuVqTkwy5IgCdIHAeC+Xxc5jjQ+rku//y7pdc21sV8v4H+PPb9z9//9fv/lkoc/3db979PV5h
# DATA /+6fsBC4ruQh8GfWQb/cFdRy+ad9ps48k/OpTygzf//oDKjWuMyASo9jAfLfPDIDSpwm7fRtcFGitO7LbT8gIg2QQJk0eE782Vwk
# DATA FMhS0BWcfJPQYooLDMqBuarPEoKSEz2xELecHjRN0PGGNHPB+HDvKcdR+GdyRgjuHB8mB2wJNn0anC6USSZ2FnQ6s1vijQ7J3Goo
# DATA Pzx6FvDd/6XwyvXcCeu/ef83RFJYyR0+Yfn3939DNeHf/yd4/I9Ufv6f4aV/4SODBQX0hVgsEOkYAloCwNzUnbJMQME46raRcILZ
# DATA GD7cPwrzf8HC879BIn/390A1CMtvuCw+lqUHSrEK02O9+3f/DFP5OXz/25XwEskAhFUTWSDYL3JwXxZnhMl1Z0MrsPRWj3K//hY2
# DATA 8f062COLN+tvscP7GnDu2tXPSrl0rKlyYQwfCGJZPW+/ZSh14b9LNRgPU1qyYkzYgC7OoyVQJ5Osh2xMOOd7n5JlaXMjWAhYhl+9
# DATA +5f3f1ewi39RqhSdu1px5/oT0fHHEg0r8dXs+RPxZnr6wk12YHzo1JjR/uLdP8KXX77/ax//4AcgM5jdgzzr6cdeXIhNFQC8La24
# DATA AoCKBa7shD6qSNgHzxq21N/5tNd+TRPl2yH4Z5j7z9/9C/zfL56w1sSK6XIX4t8EG6dkKlljLEpM9aT9UBAtfcs8/WLNxC9gA2yI
# DATA +Mw2/gd7b9sdR3KdCeozfkWSmuOsZFcVAL61VGRRgybR3bBIgAOA6m6BcE2iKgGUWKgqVVYRhCCcI1v2enysHXtm98PsnjM767P7
# DATA dc+R25LdltTSOfsLyL8wv2TjvkTEjcjIrALIbnnW0niaqMzIeI97b9yX5/ZGp0Og6Mt4JJYLhwE/p5k5mIxO1ZWooz/pzCYDJqfU
# DATA hffMKRFfkXRC5fTsA4HBeS4LyF6MECNH/AUT4p+8/kf19396/WWkZviXmH7kF5gFBHbib15/EX3Un348O/ADuMv1lGIMFOOKiFyJ
# DATA RHDAInv0GhEcNJjajRu3rnReeDPAAH5SsUlYBNQCiQ5XUWvanRbFPiehD5C8pOVLfBUy45LIb2WcWiv4UWCU/w0Z4i94kSinCudA
# DATA idRC0RlRZybCWhU9jKhWN5RCd3dPil77vhGVWFO7hDPtwW9OgcsHDBK+1Qry0J6WhfZx7FpyAuGENy6yhn1nPc5v3MCXTlQMd8RI
# DATA JZiBFQUP804LIl48jOy7KkysN4ZD19I7L3gkoQncki13g2pgC7RocXaoGv3DFJA3xgBN45RbUb3U4lO1Bd2ELopvnBEQCgNNnvNi
# DATA n/ODms9GOZMLlAbiyr31t0URRtFXeWYcWkGymSoOUhzsR0r581OBTYajmuMO4EidPCZH7lyoFtC7FaopSqWBUf9n7PWfqoH8DYgP
# DATA Sr4rip7q0eeKrPwU+dAX3pSA+Kq+evOX4ijCQ+dqhPTGwC72D886HCfLQGNyz/QDV2sxqkVQTHY+XmuoQiG6JwTvz9VKEmlXRD4u
# DATA C1ymDsaTlpIf33GYPVov0OdidlI7oVh3k5lVlPtWGS8o38WvPw8OXo0b1uo/oFzxmwgybQHJVA9++/qfhdwANCp37JwLBvSzaO7o
# DATA VGoiMr7IKsHRvJ930oN8NJhN2Rk9bjbRPQrfAtBlXhLLr3lozUAIYFiAwAnQoAKLC2DqQoNCpNodar5Y/Pwdbv+fRcGJ/WUcHJce
# DATA Qb5Q08DbPgcmBvnH1FH6K8iARsfpUo1ji6Cz9mLcwT5HThQhaILY6CS8PK0szuivR5PiLi98rGEbgn4I5TOviIZT0RzhVpd1zMk1
# DATA 7mjx3OnSRT1QDiCMvruYKrTHJIeuZ/v7lzh8SGCMnALU8BfAHF7/Axw0QUENzf0SbjR4LLUIU3qhIQaH1LEMZ0IMzKbTLqyprCi4
# DATA riX1XH15+T7z52rU/0AM9s3/pP7+Ys5KW0gn0WWJoqGdKsWtwFO/6hAxqeYUXEXf1eav8X+BZYU7mVrWPyfNDB3aK3AbHJuUoYTe
# DATA 04YoE3N02SfblGv8L9h7JQ/9ZvRwoCS2ftcaQUGDnaMLHbXFTPaedYboOaWMTM/qYRJ1B4PRKekA/Ymr66k0t/1945PKrqur+xeO
# DATA LV/33Z5I8wg3HHor8EWBW17AnQmzMv4DnrZ/gtNVdvS0oAaeEG2n5aXCupz7IjS5U6w5wqeSEka5ebeVs4SOh0Y/1WfoIrysefoy
# DATA 69VIue+u6PXr1x9Cj3Bt1DmfpQOk9D2+p7CX/FDbNqbHKWgsOLqNHBctdQXjicsTDPgU53q1eERFWQCPv3ZSKId60cNglKIfV2C9
# DATA WKmi8PoPUoVxn4Jpf68toZEqpQ6N0oU/0M/DCpxEwL/1lkoGm49Unrp/xFyooJFUR24BBVWZwHIZgKhSVlTqHwJmIrHiYCtwpZhi
# DATA Pfa0WHGjAubJTxzvtmhxv2OWmiKOlaatude6iUqCWnwwGB1QIgS6+pR4wBCDXBB2ypuJyzLO9jzG6coqBXAsrnQpLGDCptVinGEN
# DATA /ODSotrvRUzzBRa6v/tDYGZg7ZYmRp7cmisHUS6HXOYozhFQLiGcfL0ZvMn3xomi1ZpHPCmowCStIiG2OX54MfLZdxleO02Pqn2G
# DATA jEF0sfqsjj3+feQid9VtVSW1H9xiw0JV56KFtW/oVdOg64Bf+p60zYFNIjTOtEiu/wFVQabtoF+yVvOKJSP8PwgdNs8K+di5V3BU
# DATA TKdaYXAUP4V6QakeTsZODn0CkYjV+hXV+Tna+bfcDtoh121PK8v9idPqycC8hdw+/ZnRp7fIXDw1In4Iu8tQpALv9esmGlBaM4vi
# DATA 5CTZHzYPZoDaUlJ9npXWo29q/syYK6yemELVoXz2GsKmLgENyTu0BFCE2Su2iSeq2FPaKICKhN8nc7x3iRntnOXqRrP+St3vVq/o
# DATA c+hkM/p9+P8pcfH9W57/3+rK7T/kf//a/P92J+kwp0OpLrSUA0sxMoj/yTnGAbQJ2UTdYG2wt6JTIDmPZlMqi7giqgj4jKeDfPHU
# DATA b93R+Oztk7r1j1Tnza9pOl08klynepsMQOQm5Bn3Gbgxg2UW+8PPcESRLYdqljr8NRvi324KOTjIlJdlqBjlFAKr4LDjLbqDujQl
# DATA a1k0GIaNUaRaD5VStolRednOgPTgH2ZsA57AcO62yEz/iaIBOlZBcW9YHSVLdkF5FT0x5IFkXksHrU5kLer106PhSAnWXdJ5KNkZ
# DATA YWemoyg/Hp2ajYJEDjcKSrMz7gkFkOGOYdu3+pgsT/iqHo3GtDudmEQGcMQppBxf8i6jk+C46gf6pm3dP5uUaci8rESZ82djEa0C
# DATA eIv8KXuP/DMY8txUJ3pklA1hbvKeYg/+b3VZ+GfQsBUaQhMguKm4bm3BtD46nZCGO7Ixy25/zDTBEUNEyU5Bj3Hz7XpdaR+z9lFw
# DATA qyB99pe+24W6jr3+netcAX02ULHqBjbtpAhgIb2G+UCYvHxyk9nkfR3YnDXrPlyPbGwD4xyLCSLXDPUxQpqn0+ZOZ+PJ1qP1GiEd
# DATA TzvwzvrMQsE/ilZGii2WQ9ODUxt/rUgL3LxHeLfN1K9Fdsz/jrfUn6t5VFdSunf+Cn1sfgs6pN+BfRmWRV1Df61mtnAn/82bn5L9
# DATA HW7f/0R+iGiw//Wb/xi7QJAdnmu+qvJsO04WMTyKW3Y/AhwoxYK0IoJ/jlGvyj+jH8P0rK5igsaX6q4Fal2eDfUAr5gEN6Gfqt9+
# DATA EpBwv1pWl6omNO+qI9DnTqFcN5xCPLgHkD0DnYpwlc3UE9T21rh8GAqbswrAHjkcgVpdE52cSVxBfsSGXAUi76edx5vfdfeT0Z2a
# DATA ItvrHxWLmLePNrYr3u5sPfTqL9W4Lk4gYdshVfo5bLpfyS1JNnKxKcOOhBX9I+olH9Gpev99MnCUHp5LDOzv1H4n5c7f45B+Gb35
# DATA cyJq4JJbPSB1nND7+x/Zf1dPBHykKB3am0GB9Cvw4FWPyOWtJhq4u6IECK+VLyLI32GcPNLxeHDWcakd/QNxWXiRd9ipvqRgkVZJ
# DATA 3hCUI0agQxrlZGmg8nt0jvfr8Hyrs/1oa/PxZ+qs4i+1vdYf7m5tmwebWx9uPX689QmDqcpLKJ8PVewQT4dt07Ey1pwzL446aiJN
# DATA p5hE7Ncj/YSow76zw4sEWVu8TEVMkkRFRJTCaaYuS3O/IC9BdPX5NbsbwK4AAsy+TkB6qbiQIRy3WlzRsPaiQO9CswpTTth89q0d
# DATA rp4AQnDAtsij35+PpSCuoqq8O1DSpdMyx/CYKwX7KwrNBwi0nX5PgrgXoguKejWxm8iwSOmASfWS9bgZrtuZSRvtDW2kQ3Tn8laY
# DATA MTQYnllbWpdR30dWhLqW1sk8UVU0oZRKNprCBSU3nxQGmQMcdI3HAAC0AZ8RR6ILjoIcq5zeMhP2eqU6HOqWGMlSoWr1qlC3eiYr
# DATA dxZTnzlPdbqARPOfFYX8e5QA0XVQtw2fa4GxuEsSKd/ZG4c/Rpxn20k702yHhWgamJrCHJoQIihBm2o21FivvdhQoMyLQCJjivm5
# DATA iDynhDKkEl+SNSJSjAlsCL8mB2prNkGugq77/4AOhuhLiKI3xpIUReY69bAOzrD8VwwozSR34ZO9GPQFO/zQuKUy5nLnWF0L9S3O
# DATA xNMCqXC5jvDU5sJq7pOCDIzv8KG6ZwPuBd+76SO0orWWKQcNPaGgI+1JDxcf96aoKmhCF9H+qKaduljRLn8zU7OgrdTwe6wuy6ej
# DATA Sc/8VjeJ+Sv3tzae4k+l8sQ1dSHj+BJWVIkDf0Ye8MQgfoIc4TcRLqQSRDhuCUT1N3+JJqd/Lr+AGpAxq7Ko1aDvGKunl6nOw4O9
# DATA AH/9cJYB0iv8eThJj05sGhUHXKhsKRivSOOkqQLslaKxYjBAspMNX9ZAJcvJuyVAzYvsjJ+aqkNRaelUdR4i0ybxn9S+08pewYrs
# DATA Rc+n++8l34F9YENtVI0cPQOvb7SbN/5NLMkopMvOQMld41oJJQikqOYTj67CCwKsgyQBpjyFjEadFnQfaEjbbEVd2eEgPcrbWGWF
# DATA PYHrh390JmSdCBmzq7xXbIBfOVC76nOe8PFk9OqM1N/UD+eQ1qMX/WGvHXfTXu8stnoXM7e179y/JtKKNhv7iTu5VB3Nb+07hbJs
# DATA 4QRdI3g0oTzKsqahITU/gftwNES0NP3hkouGBRLEbGiXYRhaBx4eL4GZ/A3pFKZ7pf9Cx3ao+YFIOORiavGWgVmj0Mej/tDxedeH
# DATA jncITMpJ8ie15/kNRL+foPn2ef5eUtv7k3tqr9buJQXoSOENQePhZIb4jzpLuAA0dfToJmLu0d+39mnHhSxIShRDbrgiHFaHEpDF
# DATA z22O+1AgxQBIAvhUEN5DETCQ7PGU6Y5IwDcdREVx6rgvqjN4m4vPY4pEpUrgEf+tazrXNRWz4bjBVYDvcUhBVrIn9H3A4WSI/J0n
# DATA lKrA83aOejSsyo31xp6/ZzwsmrhpoIEkavgPL7zLLc6jxnPDbO3FvSOzC+aONpF36nzO83fAVOB2CRziFyhA/BJkBRQSvsRr5i/o
# DATA yecgTfwOfRU+VxLF36inv0GmM8kgRiIjCnJPXmLwIgOXGArVQIWSefPmr+NyMDqTbhMAdeqRUMsU5DRiSUYxbJVwQADbVp9kjqR6
# DATA zBImVG5yCxVSlhfy+xSVo8jKjD4Ouyer3FNt7SN6qtFkFTKLYS5wnWYem8DmCwmo4K/y88+xRSek8fIUs0bv8f7775c3gEDsF3JF
# DATA VO91Zs1eX0eAmPVg6tGScx1YtaXwrJh7IjMx3dDwJcKOgX0cBcm6zcZhE+HN2AcSS5DUDB9yWC8Ch1bJlEWIMlPnHv3lwLru2b2G
# DATA 2l7bIbgR4Ada6+HBijFTIVwxnGTiYAS76ckuWvLRJhEUfvqT0RBvxDSj6t4wpWzceUAiKglz4HkCAU99biZ+TwvwsCToCyZ0L5rY
# DATA 8WVGm4Rkj/zp1y9i4VaAS4lazsKyUl9AXoOu2Kw8+26Iy2JSnjjaAM5B3WfdJ7YbyNqAhfQJtXK9d20OfPnNaPc4Uxw3n0Z618Fp
# DATA SmfT49Gkr05d/2XGgYfD7BQ6dY/FWcomRHavMQCyTkejYs6NQ22e6g/LuoCalEn/CPFX2+7xwgURWnQT2EfrXhd0zfcCCYwfGC92
# DATA Yq+xuk+AqVoILhOoSfA0UrRqUXc1KCk7zhtBOiPuAramc9VMi9btwgUmtMtfvkUl+XO7w9/sOeX30SkdqtWHFGwC2Csg6IwfaB66
# DATA edAF+mjMB4lA9hTD/IHa9Q0MQrUaEn6MAiBDBfIjdTi8YFJbiT1BdXZvF2cKmjuM65xsS/dSUxzw9YLjyJNOg8E7PQ8Exhi1HcMw
# DATA diwRTuquvxEbk2tQVI+V/c3iG7F1xddgg30lC03GowF7g+EztQANtIPP2L3QAeaUuhftFR9APdzjBOFaLVGPbghdC6jG+100PjM+
# DATA ivseHXd3NJnEAvtem0g6i+RXOoDTWCW93TcqI0TDM+79FVRcQ7tpJaZ2ZYLoZFwwoY+BTwWcgG5nT3v8HoxGg5rEiuO/adA7U1oF
# DATA Qzg44ZaebdgqKNQg8W5Funn8rIVuHEqeycbwR422kbTl6dBkY81zP6DX/j6fcBdaZjB2wDmPOL8QsgZ0EoghC9Dw02J1aupKe4O3
# DATA 9Ye+GOhJM8j7CycLZAAr5yz8CZOEBrfdPDsZxMX+1SoqwLSPzekrOAxkhMZxo6OsXyIp5Jyt8HAIjKNgrYXpNHqDDFxUiip7rU1z
# DATA lfd1cEfpnGSKV+oHYE1HGVX+BqbCv/tDBAmVj8hZTXGKSXaaDgbylmmUeFZ6IU+mmn5jc/KdjTE8T1ZlOAOcEeAhNcqE6hTiW6dW
# DATA BV9rL66h/j/UfetXYCF/85ds5/mlc68ydybTFtzKUG+nSoEqz8VWAOM83bAgDv6vrU+JnWZH1EeDaKDrmKvKfmJU8KAxBXKrJRek
# DATA 3YPRrHc4SBGmMT7qwrlOFvSR+QWhF6EyEwByDOrVb9EW9vfR7uOdkkGp/T+a9Iwmmk06C1iNrAZe77SFp8R+YWYEIOfzaZaiYQIE
# DATA /V46UF++3Qz8hBwsQIX7p3Dphlu5P37tPWK65NoNoM876t0T7WZu+pmE7WU0SBj9ggNcbHxw/f+c1dVfVo3u86JK+udv/sIfNars
# DATA 8eyLEw0/a4ZOmKWlH/7FNjBHTymh1u3bt5invZqkZ8FGJPEh4VL+ntPUBhXm1r5lm5u3FmjOtDOPLyAQ59ydADK7pOM+tgDCi52t
# DATA uh3TBRqSbs1fvv9GpoQ3fx2tPd2oO4sFsBOMQ/Hz6FNVc8F1wSJPsOsCL2B+nE5IezrHWsvOGiHLKxJiR54JGMugVrIYYk2ilMj5
# DATA itFSPkP1y2txW5S2ErilJjiwgo3ZCmR2AC30DSP5ZDSAyagZi5VjlLKjJ6bFeFXWNLWA1dt4EAancsnzlbemMzEBstJnEwQK34vV
# DATA 2PdW9i/Xl0JrcpZhrR7RMIt18UqS3Q6OB5dMXK9JNZkuM66Yk6oBCuJGC+ROy17xi31nMqo7ZXjK/DP4XyzeS1gpW2m5bUav/w6p
# DATA 6l+ij8nPwTz4SyxOwXJkFtdWRcAL/BI/pefMlX7OD39lAHRoSjx5Sj1EfSW8pGWK9SxYIaxtZsMVSAzndXhyKNCuOEX/D8bW/Zmc
# DATA GvLAQrQc65JIVlBBig7S7ovZWPgv0ANyoeAT13BgEudk9KXvOXG0zg0NHlkyibRVgeKtCSV08nNEmFatFUAq1pLiS6ymTj1R/wUn
# DATA R9r+LStXl6RZv8AkXyAqmZ90GWqp66v6MT4GgNWW+oMkd8TEo4Fwt+hHciEQXCukX5d9BUUsmQqBQMk7ll/7XL2aW3uOFI7QkxT4
# DATA Jim2rb1Q3eedloVwob1u51TRPwyN4Vrbq9sL/sKrGbz8kOcw9swCxTrFBdmtmpYlOzxU7Ag0jW12PXEo6LUwFeRkE0X+iqM8N512
# DATA WJjemXEw1Z10+tDACkLb4qpY1Bb0Sgh0NE/bosqyuRnV6lV34YdQjLT/nm1mj1EuWGcR1HSZqUwYM5or1yEFxTZ12pVXUAb3YIPs
# DATA u9WQtzSaeQIg1cvSeKnG3m4wgypRjzriMB1Osvy4poNOTe/rvjxTr7AK+GtlQrrJpapDNKntXqz1dIerxNHB5jfdDrwWqEIIKrx4
# DATA D+2XYFUleOf+sJlnU84HUIs5kwRp81zgC7TpA/oEftwKZ3/Hl3SC6FmceGYfLOGYfegbkxQQ/FzIMSY2zTkstJB+G/fI8st0sjzo
# DATA H1gE2GXFVOPFXZX/L3O5MgyToFt/Rp6of0/hISZO3fic+hoLdUlXksZ/lbc3Eix+ibHtUmb5XDshqf/+RwkYhXOs9XPnMShjgMgc
# DATA 9DF9Q8yp+Ygj2TOpTns3m0CCQFWG579VOjXICtNeBzKfayFcAKuBMnnQ/1HW65jtsseboHpBq+2w3mCIteAGEGn+ljXV5Q3pjLmw
# DATA X1b25XAD2+miukuB7V01RkBiEXtzX2RhBP9hMVFOxcUJNUN3z0vJbla0y0UEhzsvN2nBJ/iBQW7Aybae2mYH8byaIAj/O538ES+X
# DATA 9uUeVYh4H7yA+kKF7ECW5CrUPcAJMFvQF/y/+j4WGAvxF6gK/BJcNvUV4FeVTuN8pO+Rh8VvGfvyZyTRk19gyVw7ybVendlTMI9+
# DATA 7xkquh+sYu8mAYs4lgAzb4m3nTrapyMwsw6seniNeJ09J6MScwmarQS0qeU0mFTKbOy9eId74G5xx1LyBAdrgfXFVn+UgbqU0stX
# DATA 7ndW+pgPudmk4AdFuHnYSzoLl4q9Ma7AqEz+mbNX4PYHLIB9SMPby8c/claO+yW9t1SPxXHhXHJGOFNTWnxbbo9gARoLr2GcAQrQ
# DATA bkyLrMuXRHq9rPcUNih+B3zAK0HWK7WxXCEUSu/NsQjWIyG19A8vLcCVrNq2dKtiaBjPAUuDLf/PpEr27u8IWomxk0WtwJeLsO4v
# DATA GE3XhbUhXd8vMM4PMNB/a/XLgZGHBuy/0UIAfu6Y8qEkW2rtCnp7g2rTBkIhYXovsJ7C/cQLsis62l7G7opNezjupd17eyMsSvG8
# DATA pfEvey/RB1MKTjVyQm2ChXXOTUVcqOZdV2rhNXKNJ0IXULRFllSA2gTr5WdG5WSZAUKobzw4Oo2PhEqTal3CFVQJ3gDmBWMUwDXV
# DATA Yd2EXvpOkj/35OR7cPI4EIxP55v/ZFz9Qd/uFDcKvc+Ruksdnlbs+Z6bnDAHdYlfoLwhcTC193poZq1dd1HtCc5awMuYWxGe53PX
# DATA u07aMNuHePGLN3fBdzEyDUl3aHI56hWFGHRnCJ8J0lgLMkd17DmKbjirjs7YcT88jz/c3trc7axvPuo82nqytrEJtwhpIBAjf7q2
# DATA uf7YFtNvrFwDKmzKhS1CcNRDbxLJGxHiaCB1arURwMs6Di141FgPuqgvZ6W6L9dgL6+1F9XOu3OmxLRnH3SePvvg8cZDPRW6IfQA
# DATA L8aXuGh4VX6We0NyyDHzsudqs/AOP0RdG8p0p+nLrBFA9zKumksG/yiwVwMbR5g9gvuGC+psYpKCtSlkXpK9tjQOeubJtjEWJsVu
# DATA FEUiR2YqFYwuzcl1g6PTYdZzGgx5dkmxzP2iHl6upO4o6/YTsSBzAj6vfJRCB2F/6Qqn5evcrueBU9WqOFMX7lLzriwc5ScacqZ0
# DATA 4cOlwT+45BTg2pG1w0KHimDU1tLbtzF/ob4KCuuyStN+WSfZ+4vtPvt7aF7CXwluJfo+5KTGpZYKdyFNVsjTVvcAHabZM1tE6T4y
# DATA 5mpBtDywQyLlwlGb67wwqQrV/ut1BG00ZuCyE0oM3nxB9ZCRsR1JWxJpA400TWWgg+jgVC0+pLPpKPa9pN/e3CLrLXXYkpkteFi2
# DATA oDHQeU5bWLEe2yLOW6gCK/VI4YbbusdX9gMq+Hl97uYP++W9ElB6E0Pkic2xta3q3YryXBv/K8webUeLrBgBeyDSPygFgjmk7RtH
# DATA iuC+2QRSYSuaypu8XXPonTwMyZxta8hDZTM7Yl/l7bjOMV+lVNYSksQab51TVeonI6t5Slnw2CpR7KHahQ91le1CI+jmiXfYNnfU
# DATA c5vBpqvHIKN4kbqVTQpSQ39iQqQ68SrUfSRr7I0b/KlHtnAmpAeP9NKuxZCGrnsMVqZxBunH1e7pv1QEDn8mpe7EAZOG+svxT13Y
# DATA 0cf3RCLvg04ZhkQIrIE+KeIXmIo4+s38rgqCMyXJoJlatUaJOMDlUL+Cse/TM267lF8nFJmCDp6exoZiHztmSO4VjgH1Kj65ooww
# DATA r6KriQtlsxe6kZUJAnIZ920cM/ey2vPbfulf3BYY67X2Av0PhOdSq9ahjh64ujZu1QOdCETtvsB7vGf6F03oH8lSGDA9LHNTxa7U
# DATA rft0NbF7TnCntS6GhPP5i1Epun8zeoyB9IQgOcs5yzcBqMR5NJ4dqBFFz7YfRwRTRslLOB6eYGHUDE+yPG8uph2hOAfIqjfJBpQU
# DATA Y8gkgDcvuUeVBvvxZ3NQekpTDpTpdblaD1R42Bsr3iLpo9wRui40K2l97fqTzbVP1r633iE9jZo6cuYM6T9wWXQjiQNEoijDgiMq
# DATA 2+o8IsRuMX9f2rOHv6x27ikW2vfU4QsdqUA1cCkNTWnLBZjRc+hTVD+5KvAN2maXBFkKISwZlmcqLQFbChJY81GR/oRpuf1gv8iv
# DATA vdqQkYDvk4l258Ao27FvQioDDAi0AYw5YjocZ/2JDTNloZhwC15NGR9Ece4zpgM2ktXUA2YO8rkE84N53DDAo06sFibFpVCtJDTP
# DATA eqinE0UTbByj58EkM1VREKIXrCkjj2XQ5tw4RcLA52AUpy9mkDFeRRj8C/52wqZCxQxMEiHqM0RxlvP+0NPvIPQtsKrMO+VY0VdX
# DATA rya5fhulHKWnVGduY4pCrPwu8SPJw2GPvlVPm3dMzC6J/OXGHqO/ETq6xIUbYTMaCt44IQy6WsxQFO6jGQBrJH3zIGnWaarhFs5v
# DATA 90OpffIQWeYNVwiUBSfcsQlh7WYNdUgnmYx27WXj3Pw4mPUHPQ4SVtcLVKuAObgCAeZGbS9u9BiXj6eJXCCpSvQ9Qh3oDcpB5MKX
# DATA ehNU4LZlsxWU3oiJp72zquhUnd2YXVu1d3ENldCtIiCkxe9uqm7U9gBIO3uVdWfT9GCAQcYbcRBLG/ytKJgad5ZpqTlWOy/BrLp6
# DATA HVBD3hiTjRAJFHQGqATkXkFv7jpihY9m0/atlRVWIFNuANHBHfPnupsE4DIeGtJGTx4aMhQwev2r6OPd3ac7DR2m8+anQRcgG0j4
# DATA hcZgIaBedi76R1SzgBvSr9VBRKBwvMwxXVLSHpAtiYzLruzlSHdEk8jRfJ9uyXAkBhnNM9SZ9RpQLd2X2Q89CYKNcn06Zbf1oV4D
# DATA 4cP9LLCbAq7XFsRyYSa5oAVDMj4RlMve9eis/PZs8GqsbXJCW1yxGUmIYtcmIqnCoIc5gnAcPqf4gEZE0UkOHit/t2ywDjDPTN6k
# DATA Kdc5SQO45pKram7IVXCliaN9EbAgLv5F4cJgXHeteZkqCIAG8TAY1cWCneYBqAiqtzkbosvSST+Ha1Nn9MKrruhT4goPVE1dQAMx
# DATA GpDXCYsSVNf9OyEMW0rAE4D5FQdH+k4lFvjXdnWuBOLGstjz3XZPdEA8Ius6iUNM9tUu7KCSdnHCUmgVRwzsaE6TIgDAOWnaXa2E
# DATA vXF75GKTGGXbPDoQFAIceQrDavEUuk1IvGYegFB5cuj7i+xMouBekhZbaFUR/GPmcZH4dQ4o02p57Uf+T+hcAlznPziq+a/+tNqL
# DATA fAFbiw+oxPByoba4QLUqUzdwre2ThUXdfAv5GBycZ4zj+9k8pOdmJJNSa78e9hICJH7juOeYRa58YBzZ6zK0xUUexi6wtQ31gWRD
# DATA 8gipn32KDQxNUNh2xmlfs8iC9QXZnH1YJ7woKuzg38yzIHj6HpLobJKTknxO5ctuEzixTEXpZHyffA7dGkZ7vkVCyene9b9JXiS1
# DATA JJDeke39U9Ywn+spb3krUI/kHHB0BXJ48ThpCld29YWaU1kSYFJliYvCTWLxw65TXtLd3UB8BWbZ2ayiEXPvDzJF3SuUqepGyrPJ
# DATA GRyGkJRcezRU3TV9oQ4TgKLYFBT/WCzSwh92LQDCRTUVYkuTOVNj5S8y7Em5q+4a+C9b1dvVYaRRt56C1sZ1nHXEzX3Gc5TiYHnT
# DATA PkULlaTqPTmzMOKKQdArkIPp/yu+ivitnUk2yBTh9ZhVaHBa66KNkI4M76ITtVxGH+xu4iMaXQQR5lj7aY5okcy0ynDhWMcZglYo
# DATA RfVD8Ul+6GAsuJ8Z83s5UBzV5I/UKLy8ifXLBaulhFioQJf9LLFYls2NqQU9J/jHFabK/fTtJkvX9c6ma/45qxK3yxDlFtRGBuQL
# DATA 4wbf1r6+reBtmdHoIOwGb8D6Tuyo3zAjDxoRUP+L1ck/ZNZSyPmq9cPL2bS7jKWWrfs8lkl76XjK+H+eY334frigtqE0V5WjDDUJ
# DATA qzjlAP6oCfYkI5uN7MTSVfKu5pHUC66yAYpNYwfXOHADLax3URMUJ/Pi7bWuqBD9szjbWFS3VGBoVioy0p5PcoNyUUjkEf7nC2qu
# DATA CjV1BunZaIYBLA4nL/KaBQ9kgd+UsvbghQSWZWmxpWCx/AP1/Tr+qUixuLI6qkr3JmtSzBhavlCOmbeEHDO5zcoAPuzRawVBO70F
# DATA CeEVejAgBiakgCSULORS9G5AelAv6PVM3U2e6EvJIo6Z5GtYZ2STJ+lY3kHmYSImJtMbJf5FxT6Rk9Yi+iC+Lppl2/d8IkP6IkeP
# DATA 2ipu6VQJmkiNbWfkhS+pUH5bFnfNsDgd1hzsipOnwatTJ/EJj5GWVKRWccJPXO6gHtTi5XTcXwbw42WC5ozJFg5t0L5Y1iBCY4B8
# DATA IL92kUy1icauDr2tee+Q732sZnyg3p1roN9elvYYoRqn9mSkJmI07HdroDBfvUlwLafHgMxcKHDffN4qT39Nyf+wS5TdDL20tOXn
# DATA DuYBVOxKzVwo27QIbPNXxhXejH9DibAtVq3gbKAmOPzRwah35qLx6p6iJqwGyTk5RyfMVjn+s4edDvUKgIDAW9p7ujU4vFWl92xJ
# DATA 3rX9/PFIHZ81cDACw04dgyQr8KJJ92LVNKhtAyUZWrZ+brLqkPOwzg36U8g3+ltCuoB41t9htNwvQRMXEOy9NWAeJJMEN8EOV6Um
# DATA IsRwQkdQou8kK2ahQtcqxRhVqQhyCsV59OzZxqOmLxdyKlb0t1J0iNrvcujd7ZXbSRVZWHzzhQdd29rhhOcyDbozFWoYMiuwtQnn
# DATA NpQFj2Q+yLJx7SYzyrDqFO2bEUcy/taLT6YwZq0s5dX8yet/VH//p9dfsikUcCcJsiSUFrcYLvlrk5lCg/GT2fItzJ/XhJwzX7/+
# DATA v9rw61+++SsI+vRzZ8Do4oCOtsjpyuUuY4392gSvfj4GjIBaOjnKbcYv+AX0lfM/t7WOOvZUz/hZk+xR+Kej88UnoJW0IUGBinUv
# DATA 40DHTfXVVZhpc6w9tEEWrAIMPw1i5sJsba1hohqaOYTaM7lPJjlyUJ1Ivbk2OZrB9nmKb2pCvm13Or1Rt9NJxJdN8AxM+ZNabHoW
# DATA g4PDCPw+2nvaMmQMQxq2XlrvtelejAYT7h6ODDpWqEF1UwTwuzoiL7efUs5BxemVGNeT5sXwt1ZScbrr5Aish4Ta6i4pCaxhpE5b
# DATA 76KxM9WVw+WwcUI9s3WXIewuUBf6piT3ysowPC0Xq6pN3dX1RTaG7J64Z2K6gE/VUnj2Ox3qdZQ1+iieW3xS2K2xZ1hgq4GTiC3Y
# DATA DRAqbdAD7H70yMWy+A+UzmuJQzGGIxeMsOYdNCC5ehsDPySSUYnXzU1mRIad6XERuBGnJ4DAze1FYp9G1EgFsdOdlACJffCHZVB1
# DATA /ITumO4Y+DctAv/gqyf/slFi/MCgMcjfFAyMvyWycRFhHTMCe3OflJM6CkPT5EOSDElKBPmQsBCk0jrsDqcDh4U5NmGP3pamJUaN
# DATA EbqAUYauWqw4tupKwhmKH26vr+3qfMTbjz7Z9nMT1ykzkm1GJwY/7GEDMklufBrj1QBacAUgHE3zEF7U4D91fvJ46+F3O+ufumKn
# DATA yy0D4aC0S1DC781Oxrkk/HM3jVZRQLLyHDyx07zb77fZnxLMUcNp+2YCDEgtbAdd5zod3K+dDuy3Tie2fqh5/2g4O8EFhz/TQXNn
# DATA 46Pd9e0n9cj+/vjZU+mlRc/pnxpVYFLy3eioaz669vWnNX05cQQd4ohSLqlJcdTIqN/NzkgUDUjlJH7tnCkqfLL+qj8V9loPFy2j
# DATA ympaQHrIDuy4z7klT4xLdNjc67+zoqq5jBi5teAyEXTfm+Oyhyg9P8G86iD9fq4BQX6Fada/QMi9byzyv5N08qMDdVTGZ9/4yv4H
# DATA Cevv3r6N/6r/ef/eunX7/bv6GT9///27d78RrXzja/jfDDxkVZPf+Nf5v29eW57lk+WD/nA5G76MxmeKdQxvLV2/fn07S3tqi+P2
# DATA UNfStacbBFeE/st4Wc2j6fFkNDs6DsUMqfJNVcsSk3UtuurfYEqBgwWHtDfVT9VtFa+M/FPdXI7VHVP/BMKn/x7lS+hfAXcPVURz
# DATA DxAudZGJaUwRFv0ntKn/ljdY75nTV1c5ZZ7O+j3qA9MI3Qe8SynCpi6IipZ2B2pAkTEh0oXP3KaMhK8GzVdPkwaYdf+KUZ6MIbFK
# DATA v6deyJwn5G2BPI+jaqx/9pL0aKzOZ4yhpIr05tNef9js5+l0elYr+oS5I4ifkN9jJOJ5VLWTPnhlk/g4GmJ6p5Twik/0963IFf64
# DATA S7z0Tf63RsNGskwjJ+LaH45nU/3STO/maDsjrbCvSQRdgn7HCkUeGoVf0JsOF6+BiI6XE8Wox6DhB7npJD9S06+Og9rydUjuptqY
# DATA Oz/QsKlf/fEDzD1/Dw4OHpdDiq5BlQ5ENNnBrI37toedTn/Yn3Y63DPSR45eqI0QO0AlVr9KN0QTXgZ9dfyZOb+z9gk8J0WvwQ24
# DATA MJokG48G5iY35bWb8JqyQtOfOit00EnOm6Nn6llq5wBFrNFsKlNh1yNTt645Do+n3daoDqipt703A129+X5zRf2/VRgsZhCGMvCj
# DATA 1VqNLxbp8XZ2Mpoyrcv1JZYc8mlp04hSE+/sfBxNZ0MYGRwGKBHLiJrBYRPXEv/CBaUVNFmdl0FUxRfuV7wP0dvr08aHo8lpOull
# DATA vcbTyQgc7CK7nPKt+gve2Rm4oLmzSR0WmCCGC79wO7SQfl8cUJAw7fmTx86gMqCGAHTF7PwK6d+0oMr+1k5gFCaMEfMCPoljjHAU
# DATA kYrL7Lpz44acxwsHadQshrsXuOxevEbJHn/EgeGgU/sgUze2CdI0+7mfU9b3LUVdfWkuQv6o5h9odm+Fj5EuwrTQmogrAb5Nmlw2
# DATA CY/jISUhbuwynKo7Ua8ap6enmHOvYVolPGPbYnFmHes0JNxWFBq21QSCBGu3BGAJnNSP1nfZgLiaLOAVqjZKcYdti90D8wOGKtw6
# DATA MIFt+I8h221Dvh0EkKLaH295Yl/TbRIZgjYD3Z5nB3KzXbtWmFs3tQ1GmGLKLDGA/coVJdGDyP92noHEJ14gwuneQA5SdfeaHGUl
# DATA Tk3Mlp3kjtSTkMvspewixmeKJIigQaPKMOYeJ1mjt7+8moHG3b757Xp0Z+Um/OcW/Of2BRbTG/Z+dDPctLReKBqiP0hKV78QqD1v
# DATA YXAzR4dpf5D1WsgxIu0sageRyFitwELUgmaZerRLmzdkpKmYvN/7rKhPhhkqKXli7oGlDHwETlTRbvR0a2cXdgV61/lBbNA5dbs7
# DATA GVNIjbU/FHM11zB4/FBt9KmT0E2nXO9Nm/rGglB0XtV1KADPfqRab86m3ZD2prSyfj6iBKdUWVPnmo+/D6z3vZWV1sqK52BPdTWn
# DATA PwLlezhMyTTHZXWt9E072GEnJ3szzXWJml+6afuc2P5yV1Wnvy9MacOX2UTJoTn4y+Y/nKU9kOlG05SSPwI6RtofkqrduNHCzc9h
# DATA 8ZzbEWoho7EWRwW6At9lJmpWZ4MBglPXJvHeWuP7aeNHK41vdxr757fqt+5exJRMe64M/0yLvL1RRsz6sD9F6b1ncb4jmgdvY04y
# DATA 9SEG14icr52TdIwCCt2JQEBZe7i78b111Kyrm5e6O4GfTPxoY2ftg8frj1AO65+o+yQ+frzxZGOXnmavxmA+gafrnz7d2Kano2Hn
# DATA mLIH2SpMPh87d+yxYcDzbe/mzsjwxXB0OtR6gUjXtERIFCcASKja6WHiZFp09kZS3LiDBQh2bCWpeyXgs850kh4e9ru6jFzWleh+
# DATA m5qAP769svL+6re/ffPO7fdvr3z726v61oKlsAeBQvNGtzFEL8+Ie6H27gxusLlZRPCnPTpD2Swwsg7s3mlHF6NBxMMRPY+T5mw8
# DATA VrKwhcTS9ZkbyuZWZ3t9R1FftZaP1j6Dfz5ZX/8u/Ptka3P3Y/jjs/W1bXlZKVuoXLU2moBPMjYf2W6Rm0w6gUOHAfP7hR4BF8CG
# DATA pLXSjN72856pR6N542fRQdYdQTS+KSiPAecuoh23BzO5p7fk/r7crfYxdsjsbquT9xvf2ux8vPX4EdR/lkf6DNxDQ9dLOq7A13qs
# DATA yDU3OMjDlJ1aOmIJFBmRDY2inIyw2hJK4/vZZKQYaDrMIwgLxQPLWBqSVDSj9VfH6SxHR/Ful9IunKjfETUQ8QFvOhdc2MwP2n6j
# DATA 5sCp2Vz13UV4nnFPWQqjycdFOJAIF8YUqvBTpmYbdM6c+5PeItfkHvFcrPwl29ZzS5MeYWps/fE9ixwTHc6mM1yqIZih8gj9TK1e
# DATA SV6vQ1vVGq2g2xV76FkOjjmUtEUJNNGP1OLeU/LyVF3rqYsn6VmkWh0SL0gHCHoQ5WMQ+DXtSI/Q+3LJYcXnlm212DlYb3Gd4trQ
# DATA 9jW4wFo5g84DvYop74SlQfxYGyBuKmLXWL3ZuLW6e/NW68631f99v4AhEXNPH8NqfgBhkqo9JuHOux1NOFpmYsFJAFnYBtDHYTrY
# DATA Ab6OWEAgrmLWPPBjqiG/T5ICylUsLFfgcmxGokghA1PGIc5F2udeJ53GBTFtT79dQ6fGwtyJb0Uurz5ihtgW+Fkss4XMBDFtg0d4
# DATA jUslUUOt6csBREDirI1+QEbx/DjtjU4hQjIXw7DVXIZ8j0Gz0x0NWuIssMiFWldG5CHts0wnzt8pqQuTi9R1jC3EHdZsr8mwjz+f
# DATA qYUDvVNNDEVr+uwAn+onWFIO1Sue57aoi6qg+6ZZH8+nH7/h3Re0wptL7+layM2NRpn4eQYCkYXVGm3TN6uGdFWOIjeXnTW3Bd1T
# DATA 9zTQNUSGgHAfv4WyjbrtUwn4devmIn1+qvtq9LGOqCrFVA5gUX+iqDrJOBWbSzr5KNEQ4RQVTAWFpQr3bHMUFbew1OzK/CFC6neQ
# DATA X8q12laWFX4/HfVeE4+kiXCVQp2qYfDUn3uN1X1/n1ReG1bv1u/ehnuDai5ZZGFknDGpcbW+L43yYzATwY4gnfEgO0q7ZwHnUJ7A
# DATA 4vLEWAXuOwyOnB0Ur291w9mMSxlm6+GbGNhmhr2sx6P5ZvTQLE2khCK1WaaootSOWlH2Uo3h9Dij+k9Qc4McOAUQKPACAgmGL+R4
# DATA fyRK1M8GPZQynSubPThFsuJSDqSmerSWX9ZDDKyMc+0bosgQ1NQrhyTxGz0vZEXQ2wzcDEGq0W8RD9u/b+Pk46XVgDsH2TfwJ6zN
# DATA vjb1yiIFs52tW01O/2iI7Og8VzNLO8FVbeROLsKc3DYQssscniATR3TOC7mhgOPZHgY/2keipbtl4240+elAo7V03Heu3ppMquda
# DATA q1tD7RME1kGAAZqZlw/OGnrvYDiCQxNAJDNxUulhBoYxayaQQCfW9Cl90I2VtJjXXeiS1LKoPdghHkPjEMk1D+Bo6RCTHPXMKC+C
# DATA fQctO5CCl2wZMJeWR48OD/NMqMlX6tEqeUG4lWqArblz9R2qsa01h/QTAYX+CIU784aqdxkbyrhh0Bt8RaiZezH+crO0OS9wc+MX
# DATA xRgAKGhVOIhKA2keFqOqOP3sfKBhSNVlDg3RuEL3SBuoH6YRovdF6t7dH/ViL4QOvGoZfnSPe7NfDMksqpwSwkzzzUTl/X40I2NJ
# DATA xqIYNY1RfDnimEEfTN44L/4wG4L7ZC3Uj+QezYW+u8CPxM+kiCUwhBiXxO3zgRKKX/is0JkQ6Kao5kGoljJ1ivb608OmNbKcX9R7
# DATA rdC9cKXrWAXfQUHpnYFxinUa6MXuQGyzf1ODWtbh++c8uJY+rbxxW9SHC4diYBGNizYber7sGJdGbpCz6Xg2LctnV2ZPJm8Y02XU
# DATA BsAaHIAtWdVzMAJvGqgtLklU7DSu6Npo8FIb/kxZxpOQ+cnrEfo4a+CqeuSDTfQPxfdyUOhbOzyribeKF0D9ySIqVTUudYOPwE5w
# DATA BhcZZwJ00Fje7B6rDtUEkRVd4+3UBl8JGj896RhvByn5imIORwL7u3C3IaDZh892djtrTzc6u1vfXd8E4rqtEzeiDxSZhyOTkE2r
# DATA iNtOVU/Wtr//wdpm59nO+vbm2hNUv2idadpTwpOqwbj0iGR0RowPV/d0bWfnk63tR7I6/Qn0SUyOcSrgn4ZlgIRmeAb2ZRmLmmPB
# DATA 6gn9p7zTtUxrF2yVR/4KMgGEbneoIuILePXPMW7WKsCCjKvPokSDPgEoC8ue9+K+J2nIywhsQyv/tNvap5m+6GCFVvCh+pP5amD6
# DATA nMrbGxWeF6inJ7N8WqavxuqKCfreLTYx9g9Zbyfv/0gAq9XJUpmzsLBnRVbNprCNiuDFcXoGhtq6VO261pfA5PBDq+/U3sL6Tqbu
# DATA FnAt862+FB3hri7JeOJBXfdJyP77BQBlU5mUvzTsmr606EKmymRh3isoAU4lwX6Rpb/XPzzMEOaLbgT3sNGRmjPgJUri9bgxupWb
# DATA 5NXcFTwWPPexnnz1UP8pw0laweEKnGptx3WH4YbeaRfnegQOHKXezlgdbirbZe+A+wIFZc7GFErRPN9ot4da96htKEyiaVrji1IG
# DATA LZGTLVumExFT72HS8A/1BDcq5mps+Tv3Qiv1wK50yIJCKzq3QsYFSIdp70w9VDdYjKmc7V3XC3KdEhzNNKoCFNe6XUpP0VXiCX06
# DATA 5zNQ1Cm2Pc25eep+chHLLqLyBr0CmWxQOgxVRcsY/m3uGsOTqa55NOzpJFM9ODqeGru55Ijqvk7CczPaRstHZJfBDVzpTc46Sujx
# DATA YxDiR2r11HMTCEeGeSKDxaPjhraboJIzRVhhzOTUGT+UrsVozJ8eq0MCXfsO7vRIfQBsDu0LZ6Cw9rv1EDbooHy8EEMlOsPSByjm
# DATA WTsMKux9VIrygusHNI34y6aDQWQIXnd5UUNiADZQyivEZGL/njZjB8hiOV23SIfVtNa61AZQDIOXulJ3K0+CKhEe6LBailyohmmZ
# DATA uzfDrX0zWrO+SWBfUfLvYKTYLeuYIoNFQh7o6EgMOB3Dbh9goBEnOzpQAmpvcEZ3wGawISck+e2nODzN+tqruRe/rmJe5Uf5IY+X
# DATA tNkQ7tuH/T3J4PyNzTmfjux8BOPZYasbK4hNv1wcE6qlL9F1XbU9M5WVh1zm5rNufdtXbKib2WEj2dH82oFXCu29EiapB8BnfD/I
# DATA LlkWDrBHwb0DDI6VocziqKlSbrjz8drNO3d3nj3ZQb8WSm3FYRDN/DhVL2tjD9n0OHvV6x/B8UQ1T4TMY0x5EdXv58OYzEEoAaM+
# DATA Xtzcjgajg1p8g0l/krg8lChyj7kYT9N13kLX94HVSc4oC5nnVEy7tTll6CEUsFzHX4u5jC6doM6azF/3IjHdqFfKsemZegzWdxa9
# DATA mE8pyY+O6aiHhyoORl9fKfC6GMaL8hA41MZ+9PO9QHFBdoLflLTiXqUWaok0B4s2gFeXBlxddDw3es6pSUvVtLdX1Q091AhKacWI
# DATA aOn7pXWHtjLxuqw7SjxpEB5ZKJQ51JMzNBOUBj4XP9A3oQbfhKq+1oHMwRhm2GmrqCV374Dw6M7KipAfdDyynexWtPrff/K/3AE/
# DATA QLpvGpti4E5nUpVwIOncgM55cZaXvIuIYEx0H/7jna3NRwi/XHpVIYJztRuHeWqIDKZtIKkS5UvQ25CXXlOYuQQBwOaVNAzInqqK
# DATA NodDqWaT8tjR1QVDLP9F/89PjfH1x3++f2tl5aYb/7m6unrr1h/iP3+/8Z9bp8NoNFTC9BRBjHpZdDRLJ70I7RX3ohdZNsYoJzhg
# DATA iocgigD6pZxZH6iX6kBC8WAkKN7wOK2UCOHkJ4REYOIy1VEcjvSP/piTzr19ZOjxIHtlf8ym/YH5NU1NrKfN8WLiSLOTMZCKpaVd
# DATA cDGMdJo/0BMT3BvOVry0vbW1qzX1BBZqyjUQOc7AcSRLj9Y/XHv2eLez9cnm+naHv4yXR+Op/Sheera54dWYI1Hq8b9lDTQ18lOy
# DATA 9HBrc3d763Hn6fYWgOe5tc0OT5dlhrdmz68Rlmgygh7vbOyuX7WWnAT2J2ufduDzzgef7a7vgDejjXAxL+G5kn1x7J3d9U9xYuJ4
# DATA 79mwP91feiTEMKutxz3LaihcjKU1uEu2h9n0dDR5AYy9ya48PYCyn+gJWvoAParaJ0oI6aPlmcst7XFivP0lYHZtddODnG5L66+y
# DATA 7g74C7bNYeKDFFWt+DL2ShFdDYG6RL6Q2E1gMW0lrCztbRCA6/7SJykwqQ/OAh1Tc6HXYv3DjU9hdvbsTGzCTGCQ4v5zyLI6gKwS
# DATA +pHiggewFM+HUpolbIMeTaIpAVs/b8fCGHYDRAw3URJGXzlomuRE4CZyou+QR3OoFpx6rqKbjsHXs0OyKT2syJNJreN/ZZ4mLc3z
# DATA gjtRIMYl09CSZn/ccUpiKqh+dyrtMzb0Am6g/VeDDBFdViKE1sYX/byD69NN86n7eIa5JvGm4d9qJJbdWsTFuhwau/EU6lHzN8ym
# DATA 0iUndsyUlPod2kpMcjm1pGD0U5WoweTHCPKiZv1g0u+pC2M9wlhRfNpeMaHoBBOppwJ/s2wMX6NFCS+R4MlgKk2iH0fnN29eOKZd
# DATA fvMguntb2wzhylAbJ1r53af0mUY0HsN/7t65c+uOvbNSLVUzpnXOwI6wtGth5uFCR1Zvfkv3pNrnq9kCr6/66h1w+jqg1LwH0Btd
# DATA 2SL9eYRkhT/RnpnpSX+Ansn98V0MqoxbMXkhWOzM/jh27ZyH8Tl9eBHlsF+jcyx+AW7kEOrKYjy5lrejWtzvH6IC4By1AXC9Il2C
# DATA jBQVoxJLqgdIWagi0wTK5PxS5wc3fk6wqnYzhZYXAzNsEbPOi8wj0SnhOsAECSdm2h1HPazy3FZveo34AbZV2W8+N4eKdpIPRh/O
# DATA 1zny84vo/HwJfHVUPScE3aqe4DixWIdZxb3ocJCqOx8TnXvRxcVShGnB+foB1dBnSloATebxaKSvJurWMZqAm11jdUVdVcHQf8b9
# DATA vqe+0kt4fTC6zo/V0+7U4EnT5PQmo7F6fk57BXTTYkbOo3O79ifpGK5YdT5RyYXqra3YfvVv7ZjN23Oe8gvZhQydV/r5cdar63S+
# DATA XW3Mp/AKEAdNJSfZNI0Gt9EbVBHel3cb/e6JOuPqPy/v0iypHg97jWHWPzo+GE0aOUwKeKTLh2kPbJr4bKImPdNPYDjqUKkpHpN7
# DATA yM07dy7buKN3GU6yVC0m5hkcp5DtpjEdjRoH/SNiMw3tf4K5pNVaQV9UA+qDE2duaY3s3jikwPyS3aHfztkfC+yEK6/UOdOSC9l5
# DATA 9X8gZxhoxy7oXY2ajJkDMIEl9t7WoZsFiJJYUeqOEkI31x/ubmxtUgwf++c6pNtWgg5MtwmCxjwEP17FWXv9I/hQqBOgM+g1BWoF
# DATA t3wIWwroICILgyOeEk5ilONyEOQUh6OUnLvQw2lPbTjqKJQPJ6h2eAqeqOe992JMdBxMnOl0FgrpmdgzvS0gsZZnnXQ8BtnWocm2
# DATA jfVCzwwcKsm+lGsUWT4GHTKaP21LDE+c9NVqt5mXwcsfehNiV64vXWulnUyCE5e2zSm5AapBVaTb8CaOsoLlbGOjTbXFWZ1k6Ib1
# DATA c8MZ0Jp9/tzA3Df5BsDdaFLxJnv7eRmcvP/pYawgsyGT3yba9FDXxjPGrOdggtiHVGqjF+/vtVZv6lXWkhwxY6LSRlozQh3lvUaW
# DATA pWZxYGQR4ZSBkzs8nFL8KEF44Ac0vxk8QD6nJXdXxNU1NalDGDyPiVzKqs1jtyLxoc/ftwksSdu20iHJCbjkkaqbqtNnNB3mqaYh
# DATA tcO4l6E3YZFdPyeY+lDHUTxnvg8iDU6Z0ZDq4TS6+N9D/G/MlxjRflL8oqIsZ/QDNnraH/ZGpzWAkeC/jcf9GjKRnhm16iVF9HQH
# DATA IwiCQ497NaqHircdjFCSAl0MYLJEfOKj7iRVRD1vmtvJ1VY+uGBV1S204ldbdXES1CRtjqLRKXi6k/apD45ceB8GG6i6MZKnlr5S
# DATA 54rf9QEeFDAoKyclx6nwpiQ2kk+82Pygt5Bd2lBEgAgTfTY+mqR4liJK4cRjQgcCcBTTAEh0yNFJaJrTjo102rimBG8u2401F4US
# DATA sslE5GguRNxLi7bPBcoL1avWAgQv6KFbN0m4FTKlrCspni466RjpTodizmLFKOd+C8EHLuIwWQsulGxUzdLVWuQ5gj9X75xQHzQV
# DATA kNDarFdgT1uAFzV+xBitVOU6LC9G29nhjLBTIi6vb5e9OqomR5MUHYS1mrJ58gJUg2Ow/LaxKXIFRsiFw/6rdtzEvdgIQYx7yKeH
# DATA PYt4CnV7iKfQGo2Z9C3mrfHpNR2kmXBKGJQKW8bCiyNm2uDMOYGjnAK9OJmn+c6XF3KdsNeW0ElpARGXs1vaqyIC76Ex6ApKTbus
# DATA X/fNWPUQNDSoyW6eHveVDBqrZy5ChnpQmnObBl3w99bPadsUXnNgoFcEXcIDXwMdq4Fg15mpMVzD64GSxDL1a055jMj/o2hltHLz
# DATA ZtX8PBtCKFD07MNPIrFeul4ZekgN6VSwwgyqrosMxKULUTd88g9PmzudjZ3t9Y9q+ivdVxyNfFgyYP+74hjfYpx0xL9qnTBK2RSK
# DATA bKcMPVVAsUuJd/3pJo9HZ3phBoxVfPWml5u3rI6aDoJ2/a/cu5j6Ju+moH/ECUFhMN5baXwbNH13LpYVt3oOrgRUV1JJgWHGuSeY
# DATA v2M2POHZIUelPERIHV2UB4tAXIJq1FSZnUAl+XgvirmfiZ/rq6aONaH3AwOajXW2utCal38NSVgW+Ap9xOykh4HsbLUi7bzl7Iu2
# DATA xaH6uOpMxBfJT+F0sNi5ytP/FYygdBRhrzhvQ/CefEdrLnN0sDHP5HcmawFbCq7EA415EHyKTkYvMwfJ6aocipHCW5YYXM5UwUrP
# DATA gjeOMFSoXze/FkMFUlCeJt9i8f8/DmwG6nAlwyvMeqo7UUevaRXF/5fGpP13yL4eAPe6BPsOT9I8piq8thSLQ7A3R/v43Of4D6mZ
# DATA 5y7T58Zddv8Ul4JNUDXgk2njcK3xYbO1vP9eohl/zTLQ2ndadfsr+U7ic1R/VbCXc+eoODmVHNffSZo6YGOgUXVx9IA+kQhhP7rW
# DATA ZtoCd26iIGA7QU9HqubmvkaTqIPXLH7hnf7FR3OQDUYQrjUdqY6MpscY7oU6DhlipmguiHDh9YwtpK66ipvAswD5dRjHjdpegLHt
# DATA i5lB8WsPMsRaZgfuNbFFlYmnI+SFw7PYsCL130Sg/KJ3gzy4c5kvDoN5EY/CTak9h7t7nJbhAHSw61fGeM24nXGYnRWWCWl8Belk
# DATA nnRVrL5kquZKHy52CHqiyBu2ORfo6lU4Ja2lS/fIm+PDeO9czdzFZYkSG8HNHQQt3SXGzqDkvOBC2s24UF40vd09cSswyyyBDbJ0
# DATA OBt3xpicmRCMtYO+c3bhnfayclLPUdA+KZDSg3w0mKnpJSCcZpO9C0jnM80rmPahZkjcI/yqBdM8Pb4QyFJdtREwGTZCSd2YQOxN
# DATA nlE6PJYYwHABP/crAlYRu7Rta2sOPObN8wwpbzdH0w/BwzAQQlSAiWIAPOT3jze/W4N2DK+fQ6ALU8BClpoF088LCQeFMpYJyLcz
# DATA g6cD9GYTu5iyh6ZXLGyshKxMTteNuKFjY2vF1jCaTnaJwuucSszcfG/30yQJN+tX4chQjza23TkNV0K4H15FtYI05tQE06UfIJWC
# DATA ka3KpyxcuV6DSXLpdUXOKxcntMJ8XGFqvbOKYN50VglWxeuQc2ALBzzAB8JZrLABzlG1tfn4Mz9Llf29+QHklHLoU8W58YG0q5Jb
# DATA TQ5Cul4+vPANnlrkLPCf4aiWVMvfpSsujkIU3PmL7o4AVuZiO8IjdgKN30jeNfItcXDb2VsBiiYLN/9Q7kQDx+71gBcKrxY9jKFQ
# DATA t+XpYeNbFmCZN1f3uD/oTXjT8P6r5CyWJUsOUhTHuAvsOaCbsb4Eeu/keHwm1D7GeCj+7SDFAe+Ahwi0VXgr3T64kQSAT40PcFnY
# DATA oDOru2oi1cXgzFnWPLCuZjCao2LPmm4y08Ik4hdyFukrvmofjkBG1hfznJl3oM1JZmAE8Lez2LqELx4oQcZHMkctBYMGllgWCNvq
# DATA MkYFw/2tWcHJG+R2C42StdCGAwf28IbjM+UQU3R3XyZ8t0yHS67evfWt2xaOBj4riPs+LYPOjdP+JMd08XkIzl04hzAoXF1jgA3R
# DATA N6O4LRkejqpYYCcKzCey8pIjFuIh+NpXAvUDSDkHcLEA6WcwlDM30Tf5T48OIMdQB4feAUeyNv7pHHEJDzfFLLoIEbfIrhCj8B2P
# DATA 1SPeFGiqJ9G/Bn9POpCR0O5XtJeb51XNkqA/UMNQO5E9nvOo0cCvKaEsQwWdUvoZ0JQ72w8PtehE00rGhV1pcZMSZ5K9Tb4kxEvH
# DATA 2ECbFr2JsMVt7B8qkeBnYbO6LqhaRYG16Ny2+4lB0Zum3eMO4x6LEaF6Ftb8KvO7TdVx7ZUzXNw73C56yCdhY0u8R57U+3sWRXOl
# DATA fvfmRex3u3rb8bD1N96iv4MFJ+VKF3EZqNplMvTH6g9ulfYEikQQDQyFMbJbda2ZH8dFac7o7BwSRzU4VI1FtWfDvomPLIBa6KXi
# DATA DuiA1F5L6sAoOUsp5kaZrkSUQodG1WUqKp0cIdZLsapcRgbrTpBOavEO6g7VgM9j9XhMbkXsgpnvtW4ifuBe7MWmHaT58fMh++5E
# DATA jWz2fIjodA4thY1I1YCKDjG8QT4BiOysG8Vms5oyMC4qAZqBJJCSl8YSnFgApYBbTdvUt3enpbFlnQ2ByFhokYCIM1Ye8ue2avWK
# DATA aBkVgv/qQqDIyPuvOEBmPBt2pzOCqegep5O8Hd/7ox/ff1BLYq82MLFMs3wMPoPYqqoe6vBKQSsZJjvAyCrnpgouUzUsxjB9OBS2
# DATA k/innruxDw6vWHKe+6SLMqk+cJbtm4zn+29Qi0GYZvD73zu/F60fOjyagMyVQl5CGNB9SKuESg39zFRM8REM3svPcv+mWbpNvK3C
# DATA B92SuEvuNPYBJD5n6JS6NgzyZX6JJ4X/tqSbuo2nqq1OFb+vM/lyABZsc8ZlYC/2Q9rQz2wjRtpf06Rwdnja0dFsiCJlcr6b7tJT
# DATA cM3ye+D3FC1yZKJHSkB/X26+QP6hZHAYwd+A3wzaofsM/zbgugsknHqnjti0tCh6ZWJZDY6rExeEppUGNexlMItiRHRlOu6jwxy8
# DATA vY9veXO1XDhWnA8stg87kAZFKh349D2wRcrP8Z38DIrguuOne06NPtQplW9HNyuU42bM+vbi1JiEK1zVC1zBDGGdifFUOwx7rMbD
# DATA gCVhxkED1c2EuYnhJMQewOECSS+qkM1gE8ZRcTAomTlvoXPqxO0W9UM9x0hkk1H+dAKzNsFV0nwRF6ZwmccTo0V0KfGl4z55grS+
# DATA OuF3OoFYl17HVh4Sbs2pdUoHrRWFUkW52Ee5Vgv20YyCYIwwYRoHdGdkOCKph6m4GEQdxtGGhCgEvH4UbAgAylnQN8KxH4qtkdJ4
# DATA UcyNAI+hPy/BW+uVu5IOATUOo6MQ3wIv67pDMdtOnqJrgU7xlHkBMnpp99ziBWR8KfiTWwgCNmtgYBPlaXwnHI3FOCEXfM9NQn8t
# DATA XDNg9WyF8yypIlkTzHPkjMFRzcnlcQAma9QUpbrThXRGCtNLVFkHCoKmsqB3nrOF9UpZUFEy3AcHUTaGUK43bJZkQyZJtJV4KQB2
# DATA Ugk38ghBu/dsh0aErhYvBeushSqNK48/co8Swczd7qaPDPzDZ1kcIuwmnfhL0p3f27yVbgG5xCYHJvIJunjnXSWTaEXLUrGX4alz
# DATA KRMCd9wDWy2TDXCYGI687eWpF8kam2uuI7wOdcj8yeglwOYYzS9hdYkHHJTr8HkJEVEHpxh98R0T9mXbVXAKZoM9gL4C400SR/Hi
# DATA AvXbvhoNTX+alW4K0zZsMepzO5LwCZx1k4tJ23FBHMIp0dKQN9jaPAfBJKmUtTgykPNSsa83O42IHWWGo2UK+G5ZZ6Dt9QWSblxU
# DATA YRVnSPuneAvpgYaItdTiHX9X6rHgcB0deyd2JGae8DCNXSceX0Pmok3SNHRs/2txif9TiadBPPcieRhfwhthbm1FbwUn9i8p9/cF
# DATA BxrDksyA24VJCKE1enu2sK61gqsP+3KEPH3KHJKSZCHcR2+PP/Rco8Qu16yAZnsZv6vc5EZ1TuPV2Iu5T/cG6bCU5mmiWBe0bgGC
# DATA uaQjYfz0ikJtXBAFuaFCk45hxVj5QLBlY8pkNO6jbgnQcZqgN0Gstxr+1DCQzZ5MDQZ2aSXkFGrluqSLZdixEILIzxqOV2ADvAKb
# DATA AH0ck+9H00X/lE5/EXfC+KjOc+kA3zftwVfuUcJQLj6sC/9Z649trtoG4iIQqoX6gYafMXGT/rjgghJS25T5ntjaUMbU/QAfGYjN
# DATA uAZh7GCyHsOfqGWgEiKRbpOC+ZJ504KroEbLtrNDXpbz/viiCTFtS8V05A5Jx+L16PbKt+/KIRvOfBgbxKPnQ4Ny9HSUM9IRRsir
# DATA hqLGYTXSkdsvSWiLeCj+hCmqdtfDRdFOWUDiJxVRiLXvtDAQ8ccMqZBEPoyKDQpRq34RFRnARCKM3L59i8MXI1aYRtcn3UY3VVWo
# DATA 4Xq1NVTx6w7lBoOcos0v00k/xdWozQ2hVNuEu8rzchG5/aniWYexQYDA5FVs36W0tpUjUStV7D7m/u3YvQSnSN+XeLvrl/5VyyEf
# DATA sVqXmEOxgTYl56t1NAzpFPN+k3bCApuDQCGAQsw7Tk4P221vOZxkYLJZ9xD6k+Ao0/tBDyE8X5I7Y0eciopBlHkTopsVU9yjSvAI
# DATA FbMnVPQ0wGDB6eUknQAfBU9koh/I7ZEvmD3Wgp3lqyHyYzXJXYrdPsgMFHV8CSH2UIkL0CTxxipDEfVHbUMd2DjsF8gXMDjfR4DK
# DATA ES9EpDjhfoKzyj2B94nICQufBQVXX0QByLnIF07KDHHH2WDsGCodVwerMde95/JlF5cavXctJEEEx+fDrwDCEYgBFC7ssuvVIIiq
# DATA M6i+psEFK7gETKJTWxI6OLxUJdO84G2LOrvAGgfbFF4sjjRaKuQtLf1bD/lSCqmDUdeEhDMC5WF3OB2Q4Va97LCroW4fnsVFlxxT
# DATA 1GRJKjodmjLsefhwe31tVzsabj/6ZHueEyKoye9qNbnr7O45Ddr2f98eg6775mVdB2HKANtcz5z0M8N1ah7iCkq/SnoO89VZ/9QW
# DATA PwMHoXC0OwTQgw3KmbawEqdDbvfaxT53PUT006Dp7wrxeeUQHxxFog+OiJrNW9hSHwJ5DJHxrih1LRWFelwZmXkDPpRyl7pqmLAH
# DATA mjJF8SnIphayr7QpW2MAIPFSXjbax7PKvebKdpulCv220OZI7ZoxHy0VXvnX18u4QF1C5cpms82RdCgrqlmLYsY965L/oq+IbdGL
# DATA zkFb6dSrL+9w6/fXOClOWtl58n107mmQvb3C0EZFtbIZAuxU6tt+ErRj48d1m6hmcQOhv1l7vgFdpqLwvQ2qdSPW7TfEn+ZtnuoN
# DATA VLFHqiayci+85SSWT2T5ZAZ6Ucb6/V1ZMt9u2FxuwzKKlHphBKarkWfuCaqXyqL3hrWY0Ki70wFS5n6uUagaSqBD5eJ8nGohnAnQ
# DATA szi+ykGVei9wem2CbvNFdpbXJIcMcYzS4MHAMFPV/LCh7lWQ8Mlt3AbCqB7U5unq6l6HgnmabB6XyQmq0ZYC6ZcYM7Ak943MKtZE
# DATA lHV9o6/hr+b65tb65m49Mr9215883f3MPFj/dGNntyqhUTmppAPgWd5oARW5p0hY4zxBKFgmZYNO6OVSUAZeA/QvHT0qWXjdoB2Q
# DATA jp4YgD35Era6Al1AzRfI2YUYfJT+HWCSSgsAFS+E4qMw672SMu0cYBKSTGku/bSqWCulgrXZXr1EsMa/82V/NMs7AXfz4CVHRqWj
# DATA UjVcykwOKvTODVSoXRQMdJeNlxmKhMmJv9TuF1i388o6y+A6l7RhvVsQkDTSbiX0jVM7KJoKsprnR+OibUNyMYOZuqQ1mAjD6eB0
# DATA l2N0uyvzljCPQODQOlG4JdejYCgGUKj9ggUBq3HjusuBzBbYsQL7YIShOecUg4q1+mhCMl7JAgUV+6f99ShfjzUPFhBF/MhsZw/5
# DATA +gK/tjCQilOFHwEdmHvcVJ0OzEOn456qko+dVRL43udsJm0Z812eH9P5aeldJmzsrUiCn7nnreUOQ722R6UlzshFoZOkojPKuKvw
# DATA zmLJbKg3+VVFCMJNlY65gUDuAsv11lyw28Jd3b3GGq04Aj82McIoBDfEW64yYePC0km15VWE4csu+hKsnDRNeRiRl6RRflQGuOqr
# DATA q9Xw95CSlA+wUnict+ABSrfojiv5VGIlOXnhMAXclZLD4Xsv0RhBxzrZ0VCMoUHjvuPxKw6CUAVafxHzcew16LyjHgT8TxvslUrf
# DATA AY+J68Lt2fxApRLGVfSnohGD47Rf0e0GN1pZBAlLY0yePMWkcSuVH6u7mP8pJHYLF+4PUYld+KCqgYJCpmygTgSSTvVGZUP53jAz
# DATA m0YvbpslKF7DkftT1m0i1Hs3b2IKcM7FLSSAsvAeB6oIZMhWed6yeJulGS+PSKDLcltJWHGSjGWwH34pZCFXIiighLALvxWpi0Py
# DATA ++LtaRk578THeT0x+cwp5GyBxuDq454uPnSud35xebEQ+Yi6fXD8gum7Sh3ZPO3JfA3KO9GiBHQYeuc3HVm6RIQuemInb+kO5s4d
# DATA Yy7trex76QIdL2WEmMSWkCetmAqtAji8ZXQ7xVO44I71yKjF7ai8GYWRWX2bD6CHH/ZfQeiB6nGDFlVAbbwcAcQ/qOWW0VY5UWw8
# DATA j9LuZJRbBO2JxQ0v3Ge/hjumbvbSN+Ar9w3mQ1i6HGPZotYux7rl4WZARWXgyNIOxLBHYQtQYCeRJBB2ptyjwHUQNk0Iey20gZk3
# DATA ahziQ13cGg0gmtJehsyhQ22K5E/eeTB31lImgCb2OccjTAIvpXbwCaRJNC+oVWWwtrnV+yMRV3sMcnDoEOvLKslYaxHKqr0er5yO
# DATA T1ZWbccTswQFJQ5vORqqd8N1nXHr4WCSCkyyYHnrMHm52y4+T+ZsORRwvY0m0L9L6bx2v1iQcL+7TVyq+bUH01+FykHMRy8rm5ty
# DATA v/wFNL8l559uNe/64M9Tu5VoBEgML+xpD0AWQwOwiFGm7CeJUNeVz1PF3kSRs+xi5m0smVWkwCdMFQtkfeZEz9/4w//+Ff8PvbTg
# DATA nH9FuZ/n5n9eXVl9f/WOl/955eb7d/6Q//nr+J+flFn/zqeXy8/cBVVLHszWfJzmkIjZ/JyeDC6Zt7kePZ1NsqeAf1GSxjnrKnEq
# DATA D6ZuPjOPZ+p6ocjiw7XdtcdbH3Weru1+rEUtq3C3JtnYnI2OEr3SweiIfAjBVUzXoXMW3+SExTJv8ZO1zY0P13d2bWJjcFTFV2BC
# DATA fbxGT+/SI4wc06mO794upkWGZAiidjS7bmx+ZL5R790X+sO7twOdM6UerT/FafjW0s6u6lFnc+0JOnI2TToTYrhLf7z1bHtz7XGg
# DATA QEPkvuLCeKkJVEVuidvrD9c3nu6aAramg7T7YjbmSrYeP+rs7D77ADBp4vvXeiPcZLiBHtyH/0aDdHjUvp4Nrz+4j+kdEQolm7av
# DATA I0SeeopBXg84huH+Mv28P9ZP4PJjPVzvL48f3F/G6iFCYePR+ubuxocb69sU/tIdnYz7ICkgtJHGNUJYo9vvXzz/vtoaH69/Gih7
# DATA iJjYd29Tmd2t765vlpa6dZNKrX+6u765s7G1uYMgFk3oFUasdPOcMnrSP/nLI/x3+mrKj1EwjpuvuPxpdqCOav9QCVvxhdr93UGa
# DATA 59GOmmy6MNu7s9Fr5zpEqlOEUfMh1ObCp1VDp7Fy0vQmfvTs6eONh7AR/3hna7Pz3fXPHBtOGCjNBUnjvsNMECJjK2jbE/oiwk87
# DATA OJsW3EAYqC4Iv+iFby2Ax9YRgGw6o6NEfuILDYz8USaebmfdGYY70DoFPDkK87ix+b21xxuPcBbV3RYpK36jpwdJnIcm6AX72yzY
# DATA iZP7AGL0GXNQ/Vr9Fqpr4ufPMewJX1R07NnmztqH6521nZ31XSTBceJgG0tCLzNIwfUrDHEMl3bCnLym0Q41MoEBPQZ4gjs+UNDc
# DATA LND7MiE0HvRvYz5oqDIIawQvYBLOKeSk2YwvKNJtMhVAU81wSkmvG7XvtBSr/fF4MvxxOnv14+Fs8GNFL/ZWVbd+PBhP8Y9EFXre
# DATA bN5IvsO9gtt2c6N4JTvkXrhQ0IkJw8tnh4f9V2r7nsI1SWs0LBFKrrCiAczITm+Et45L7ztnWXnvPYhu3rm1wBF4tPVkbWMzlI/H
# DATA EDOssTmBfO9jXB+1WnTY+71hqn7qs5/m3X5f/eaJKoNwu8wJ1d2TZ1RipHFOdxpuVfJy3rNqS0jWdHf1Qr/BXaJYnbS5lIeOwWRD
# DATA WUu6dcqDZpwkyWUnPkijQVVbwKV1fLDeAeC53uRwBzY1NdVOO3aS5Zbtawrpt9v6f3QAdJiOIyUsTRXZhBdg952S+AvP+gdqKnPU
# DATA WIC6/dXtlZU5LBsnaOezJ483Nr/reoiG8cmrscTnNCYXZW3zoRKvt7bdRmujnBwpQeWBmHlkeSlvMuioV4m8XoWovshsfbK9gX5Z
# DATA JUOw89YW8yb8R3OMOnz72cTObG7tdtSH6w9VPz67dEfQW+Lq0O4L91DV9+zx2jZed0rR2TtkdxII2ExBJKWxiujCUTYHmWMub8gD
# DATA vZ8UUr/akxtWAndO0heZRcC3gP2IJHbnTvlpQUJlqy9QK6wdByXqtCMLTY3bFRqg2CRoyurQWC2GN/32HPwmpQ5KOF/C+Ofm9yx6
# DATA IqmzapcMjy1nR4X/IFPoHPba1CLVU1xJHp+PyF++AYSDD6W4bXsQ+5o8jsDTzVr+iCgWXn+wsbmmDg68DNkEOwLJH5tLBKa+kjiy
# DATA 9CSAG2tC5KjEgsj6GrpVHDn7yI1/s8/nYeb7pxG1Eo83nmzsFlHyubdlOPnp4TSbzB1dCE0f3attn/vDUd0bgvx9AqEOnSFBy9aw
# DATA VfOV+UUfmZ/mmwqRAMf/8OO1zY/WHxUB+ktiOJ0z1fI2scnD65jFNQu7ZlhYyw0QdK20wpQY3tD4y9B436K9VJl/gmmP3rxFKTp0
# DATA t4CccSh87a22PJxJjblv24BrC1ZuDnwoLrQ0AtK5r8tRYEshgasy/lSrB67I/8ug4S8jAtAS285dOhy0QHMCOaffCb2vyFoi2k3m
# DATA R7KU0OfL2Sznbo+iZVIeYXe+xRvnOBCTonNWcA0Jsi1eE9ANaU1yLaSUGqdnUAa4FQFuCUW1Ewda0EBXp31Z5DZKlI3rfLKxs7Ox
# DATA +VHxTup0l2Gv2rrfvoLM4m88nxBut4uFYrIS62ZBVwW/CywOG5KgBzqBL2sHuIAL5U3J+/AFAp7wU+B/c7icvr86c/JI/SuxtVXx
# DATA STrAFKPQxp6A+DUI4IymA4gaaKEFswq5itb4ez6XcfYyHcRJBfCmraZ5MOqd1bGqhyN8TVCcmArEK9Z0U4MobvsOhg78jcfCo+hA
# DATA 9/22vTyL40kNPiSQT/rsHfRlkp5ilvtXU6OxkerZsJJ152w4TV8FdauKD6tpvLyaNdDHgD4H1TnpacJ4A84RXvRsSsGLhS5SdUPF
# DATA JQo10kdjpg88FdmUhatrYFvIu8fZSar9v3NSWeJugkJ7+v2+n2HGfesdrIVmSotQo9Oclex73If9kpFAUQE/66ik4R1qpB0L2xW7
# DATA FDBzqPrxjqiacUFZin30Jls94bnu9zBGC8xQ5KdvQgQQbQ8CUXH+C1yr2MYeVLbvqkmtyUqqBnVZLGZ+Wb1eqD2tZPTaBNOLl/WD
# DATA nzZJeWpwffVz2Own6av+yeykDKhfovJ7gPw84VyTMTbpCkH7VjPTuapkG0AvdGf11t2VZD9JrkBsZPwuY/nh7NEyVcEkc4C32QTw
# DATA +pbepxRurDeqtftepof4gRNfPOghYhtsNzfsmOQVEYFEeDXBGCSyCrmwfXqE6mGzq+QvaAri74a6UR6fGD43ZjdK/PzVygqqZXU/
# DATA eJfwT594J3MQWS4/QRqb7/yctNIXF053tGCPoxSWGjS7JovK9FR1RxGeh+sfbz1+tL7dAXDN9U93vZ7QzEGESc2bV1eVGSOGPvVC
# DATA G2VoK8Kk3l65HX4VpB7ncXowmk2NJRl/LYsGLpp9TACSoSGft+lC+rnt9X/3TF0uHylJ9aP1HSs+OvgrOe9OLywfPOGG4MUIOiCU
# DATA l03Yptm+7hN9Hxl6xkLctlpZRzpwWyfcpJvxQqMBcVut2+PHG2D6KpqfDQXdJ4JQat7wZH2dR+9ckbCWoWqaqJEPYAV/SC4kF/Ju
# DATA EyToqfO8b9Vh6M9IzAitbgULPkxYSx8BK62LI1JHZwuNaUjV1KMfzkZT9udNDGkoHBobhZ0JbL0KusSulpLEairFGTd4rxgb4Hyy
# DATA 4brFsxlLzxXx59lJVYXV319Bjtte3wS6IMW40N6h5UPvIzPvai7UEk21wpYeg/zHVlVeZilTedvEYKdzTZpwuDJNwOjy3c2tTzaJ
# DATA smrJyu282G/5nq5+32w9Y/A7G3alIkzoutoBXddiOopq9RXts8vow4J656DmAhVJMKSQwiEYE1yltJHhuCSyF5Q2l9Bmf7ItB+uE
# DATA tax/+vDxV67mZtUPhMOUKLtZ+UvDxguJ/+pwMMuPhTxj5rugN+YppPPbcxwMeIfWRLAAexhkw1xxkA4a9dsM2A9UqAOwMJxpK8/U
# DATA LkjVMuXtWlwHotyKE50QJincOrkf6oOTfpenQ3amZOXgxIwmKeaQxl0r3BCFox1OVQOgU8GXsQn/ua2I/3HGeYV4C5na6v6MBNS3
# DATA FZq3xY/fHDUhr51mMaJ/xXSr4XD10Nd8tMUpzyfdjnN21UHKp52S42ypUVO+KpxbJpjUZomhj4PxTTmzE/hFUPnvTPi7s78ZoLtK
# DATA u5voGM9eWG2pThrc/UwWT475pFFQuGQhkzA8Ls8kbGwXk6yr7n0CI306mqJOjYI0AVCT02txQ+omJ/Jn8fuWewuaQGD5GMkkF2iO
# DATA R+Na4m14XdYNS3LYiGNjmcOpCitI9ZcemFKeRd99pVyLMy9Tozprs+gMZNoVv/xkGzyy4tCDGZ0Xy/vs5X/mjWHSP3vOzqB8wiV+
# DATA EBV9mVulvk1hgWx3e71ozvTPFGCh47CjZRoJLlB4CGRjolKUGj2YFTocNpUpuan/MtNsQP/uTEc1xoOEsC6192pJ2QRWO7rgYr6N
# DATA /0+Z1SYMPmIHhitqkk7ENjS3bkadlH+vj7L+nqUk3AVgYg5/WQ59soDNqcQgKABjPVf7BtGvVqVz3RU3oaWO77WdrpSW7vWPshwo
# DATA NcdfNPPj9Oadu7Xy+r8KZ4gg7MxbOEiE/ncJp4mStX2HjhTX3OVBvwX9oD8c4RF0/BjkF+pn0prrm7mIW0L5ObRJK92eV35GDNd8
# DATA PL+PBxxqLx1CTtQdFZLQ363bmpL5rqi8Plhja6FMr28zQfboNGdjcKuqYcPzP7Iz2yA97wLfkZLKTNDqV7z4i7nflHT0a/e+eZej
# DATA L7AfxJmznKc4HN4D6mpFf9VkAG/wal8qNl3CUYElZI9km0ucVpGxeJQksn9Gx4JoMa6SxfhLS3BKx4s6BPzhieuOuVH62xWj3RJX
# DATA OYR5R1SvuG901+fuht6ZfteuaMl80R+SJpU1UahMRVWUtbPBa3W3Kdrbrmb7tI+xcXzow5Uh/kAoZbk3xD3b8UUsfP4nhfASoyHE
# DATA gjwR+zhr7qOAMYcKsELWzn1hCMa+5XwQsHOVtoGr4Y334/VPiwPFcguFIJBv+q5VV1rNM8tH/WHkdLhoGAsZxQI2dqyusvNY4lKG
# DATA SNnzBRwNgeEo8qCk4sHoDGDLQlpD+1bdZUycpiMBY4aYCYZdBjZw4+WqTuDkKpKk/pKqKPglrSP58WIYinERnjtvBgnysD7csvT3
# DATA ZS2CMNS4EFrxNJsggCL7f5SAJIfZzgfPdj4r+nk4t3op20pEoSqhOqCjC82Q1EYMp3EATJKink/yl93JtPCWHmNArpJZnMwU/Oqx
# DATA 2hkfPIZ0HquLaOgKEFXO1WKRJBhqXsTvzQ8Ki1WNZH2ZRbp6po2O6gtCT9cG2SHE2/WPjqcuo83P8iZQYkVrTpxUPYrBzl7FSTgJ
# DATA NAFU9Q9YC0wB9c2Hjx4/5jwFszzrYGC9gNI5nA0Z/cNsKa6CMB/VBkmnN9W2wqAq3UnzVWVWaqeBZjo5wh5hsnvqW7eDMI7mFzhs
# DATA dMbiwZzXM/V+320FMGEgxrvtVFLUj8Lc4/0Q/uhoXa9+S2sCr/GvTkCJqlusORWgYMwqfXhBGQzrTjVuKXyji92kVNelOYYZ7Lon
# DATA xqdWjRbVGuewAASRGsT1nc92DNw60jTza+vp5tbuzrOnTy8q1pAOBh+eWhddVEHzp/ioeWJNKAifT06NoGDJp+pwwEw52mv93u5E
# DATA zVxMeU8tLN6ENMNhf4p1UK+s7W5sbZKuZUfkr134kAXOyNzDVXp65p6g4GjWdreebDzsaAOw4redZ5tr31vbeAwu4NKP52s5bose
# DATA ucKxo2UnxQz+WTh6csNAMfG7U2I4MkfRq1IeM3bk5XNWrNQtLfcaf7Lqw6La4Mmq41hc1bnHyAA8lTJotGWhUBk6ZktFFnu1/UTm
# DATA LZ45aRTwTiPbk65pV+amv04dbeL2PjEkg1A7EClPiJeu4dO4nRChEOH9QShCMjXYynQvl6OYWstj+NsIpXCdc+iNbq8tKkH/R3oO
# DATA Yr9fec6GBV3aenzw+wWDhT9Ye/jdZ08R8LQq+JmyzxSE9bAKYATgi2CpU+QOvMXQYUp8W7BEB1UDk/RUX7NL7gjO7cAiwniuHlU3
# DATA /yIyv8j1a9NlGLh+67DUzZSk5WygdNI9BrtAq0z/wAVUXyWmTIVG4h3oFGwHjQqhzth0X7cugfFyCioFvtTbjmINxR1XhohRDcbg
# DATA Xmv5EDuOUnvyol5UR+gJwSnbL+SKrQW1A1x6vnqACybJ4hoCOrGxlGTszrKnwLkkU+iBvw1l4ZLDESydBBJZmA3r0QLw9JenG8ld
# DATA eloknyi2WCUPT8w8qYvJl6tULTYh+IOnwrPxCCHNBYVETsCtJnMOu+Ai9Wg6epEpEXI06NWjYXbKuIp1ZlESI0KvQ4i0LdmsAyVd
# DATA p+hj0bQj5gkWYZGIe9lLmFPxjftyoVspzTHqwz7b2V1/ImRAvT2cJtRmqQmcLHABwikSbg1egDdXg5HmKytuNE7ZSgo1TnhLmyCT
# DATA YEmXBhuttSGirWhV09FWJT2rF4QvScxaAUqmKXELt0zxc9r7rehtjpLMbkIykeZPep+Rs4zDQ+PT01MKO4NNqMhWeKdCAfXicrHH
# DATA zBC9+cV9of7mI8TyEudqAbFB7nbIHTHo8bQpeSo7VX/DgXOmEMrsvIMZ9GrVi8JnO6bDDQ/wjwsZN2V2E/Jm7XrrYezdiG7Om0Hz
# DATA hbS2a389Z+Uk4B05ZAYhhEgmOuwP+/lxGT1z9KB8gxBertkBbH5f+sKdIzMqHhWKOM6BWCJEGUTGqEUoSqHpoPbRpajIt2n382gS
# DATA J+kBvdIdQTWJqiEQBszJ+6hcXU+Nr39crANtSN52Kt7gDFU0blR7XEWdZj0JRCvTjchlNDLikBe5bvdfIcFgngdzzMzbSlTND9QJ
# DATA GaKvXOmelSpJLl40/+kXV7YAcgX1kuP49mI3kTOXjjHVYoJVF/TJSOKWnLw7mXwBsx121hNSEfGxaMWioklYdheD3dfI9HIXhCT3
# DATA 4iU6JE0vKNCHMeR8CR9WYb8emR+0CAGRPzhbsHgLCPRYrPQSQYu88C2Ci5tWg7FSHrSapZISpzPW49Z1XubGsbu9trmz9nDXRhhp
# DATA 4POQQdxealAqLb09uVcHrohUn4vwDXdjLl1GGA18KtiOFREtZ5nL9bJXYyXKYlSj2AeF/NPOojM2O1084dzoSt5yXTqLqEfmXUS6
# DATA swnqsNpvJUOxneil5k7QpsP36vzbLn+iDZOQ7QnKG38STJoQns7CNVR339wn7Xm3qW0GuFnsvOMbnJm27sBctT/NqyvqUjJIQXSW
# DATA qgSRKl2S3B2OGHAJFQHX1TNzbyQbo2AtJU5CDzzpH2EAl3u03E+XXKN4cVxUS1K96S9527dn7Chz5Di9vDDrlMyKJyJoBzE3Ih6p
# DATA vA2F+3iFflqx0W2lHvkHwBelw8cE7hveKPkDb1eXj91uy8D1GrtqGw3IuCjfBoRR0VMfCK5UHC2Y6ql9U6e7cS/RSUGB6sXzUEGL
# DATA 6sEjg2PGeZfbbc7EiyWq0PBcZiiBAUgSiB1cjKuwbebh1vfWtz+DMPAPH2883I2TKrplhjv/eBWHVVzJ4uKQrbOEZJnTbvqEmY74
# DATA 47nUsnLAXydv5ALXDMNxU/qWc7GFcE4DvGl+Oj4dBWZlicojytoIW5rVn0mp8CONdTi/fku6B3xdkxZCfyn40nfOdxBWGmn2Gdq7
# DATA Vr8TxUfZMJvgllQf6nPi6X2Mp2LLCGzGd3GOMHKhb8nqkjztpwOKkNan1XHD4YflcWjGJSMc9XWZ2GSjc7hMeLLu4DuK9XLUNDrG
# DATA 4vLhXWT+MAyCw/zB5SoUuHXYn2CQyRASMXEJ319C2/mxaHnaX29R/C8tIqIExYBrY7Hpau/rgoOMF7pFzS0auhUKH3lLwOUiVO4D
# DATA sgk6kSXXyN1WZ8lIFhxoQZvnLDhIT2J+C4FRrN8yZLGiqlBI2GI9cgzNZR1zxo5KPf2roIwzva0XwfGStx1BKFx4kTiAKh9DAFLL
# DATA Ji9DvrwuBJ/WGfhM1bUtLpVMBispk2KFIkSXmQG8mUEm+Nh0DnRsJKOCAYHj50VgHzGOgDXk3bEDn+HwM8O5JMvgrKeMqSFuUD6+
# DATA RjueKKI5OsH4EIw51+AA4qImTZCVSBwQPQ4KR67K0KaD0WgQcIXXnbBqMfOIvACoa+bGHQwIMEghC+ujAMJnfccAy9k1cxx2HIOb
# DATA PRtWlRNwMefLmC29qOrahn8XtNdqVkKKaycEnabbxrlwbfDblwxMoSqpQhKm4PnEUvIq3y73jCrYhggjEXosRDnnJrIk7NV+qySL
# DATA lLn/6wColxmrfxYxVplO6e/8y4qY5CD1XoBkEMJGgWKYu1cwnEuSC9M7N2DGpQmikHi+L8mEKMLP9i/8WA+5oa68gRbbRJdSOwb4
# DATA QOiaERhFWIVaLjYv3nnS1gX2L0lZNEXwFpTD504DZaFve/uuS1t9sa9MpF+F8FD3PzdvnPC/0g5UbpXQPR+eMfKSMxlXmeoKoCdC
# DATA 2x71u+RG3O+pD/uH/WyCphzxkxGgdPdr8zeJxdsEyRSeiOra7SIfT6wiM88GWq9fW5Dfe/SG+D8n/WvSEGs8UoIkMyyzLVgmfqXf
# DATA ODd33aMgHNalIbEkYKSDi6XbEbhYNrb/RQYShI/rU7D/BzhspReAL8P6bkKsJPLSUVwWOHKaTtQVB+O9oZvLUQEegzkXFWz6GCUS
# DATA vAhLmIZ9v1YLinX7tttfBuiwSHLnPLYbEuOHIQQVWaWU3UdZc3I0GB3U4htxklzUAYuvPUhPDnopFmv5mcTqOksIRQqENLE+Qsow
# DATA Y7VX0VmnwhnKiV9tmU1qI1lbWnINhz1zRGNLA/15RK4MetNRts3fBxdlrbM7lvS8cAil49RjZqjEs2cR1VzQs8cxQxgtzbWAB8ii
# DATA oeVS131ZN8aOY58UjwrZBKX0xFSvFwspMchbkMDFfM8JClsBv7oy4ats8zmyVWBMVqrSMyWFKo1uiKm/i1cxKlg3isOOba309hUE
# DATA Sy9+Xe5lECi+8L3po/XN9e01YS7+Sq9OV71dWCu+6BGVSry4CS4qokJkoxr0eUH/CF0ZBuFcKnoiXvRiA55FpffIxLkyVpUL+z9V
# DATA AfYYP4HO0/XNRy7erbVmlMjAl1HcFA0XgQ2L41vQJ4JrWmicdn8HSCGbo0nMKbe4hxwRaV48vxBnvKawNggC39bPwFuWWtQDeytb
# DATA N9OjXsdbl6CnPl+LqfH5Xjg2Hkk24S+S+1qulh6zfznweuy0N1eatNFYi7Iw3jTWzlj3+mB8851DX83X6Pu3VAq4CgFvGp2LhTdp
# DATA JW7JWKfD5eyQpcoAwaALrA31f0qEfenmsVTy4gQdoSjPenNtcjSDyX6Kb2oC6LkdbxADjw5mw55i45Eif+kgAiKr2UWOhHE0m0Y4
# DATA b6DXgpwI0Oe8aRLqQs2AMd5JubFa3GhI3DXQS7afGjVB2RckbVaWETgrahJSNTNGiVr5Hc1eY0JOnYv1hyUgYC9dmjASJqZq41S3
# DATA BnN0hc942yzcQU2eG2ITaT6MAGv8Hf4DX+a4YZJgmmp43YSOF84/HeDilR9dKfAz7njBKQdfOlkcrblfvQmxF7+MFkP1b1aBV9rd
# DATA eNgULWvnVY3lhzPVmTwSuxOJYnAq62bvm60AvfD2aWGeHJHTnYC6M1v10kngN0FVadGKP3+e7ZwtNl/+5PD3qZ3CXjQbqrsZzCRs
# DATA Gah6liuqWjInjkUkOCfaNII/rGlCboGqWRlP+upICOBlanoR5OWkwDpW5pmxArgghQ6cx1iCmQr+DZf+Yn+UXAz33DbgDORTdZ2f
# DATA FDq0qki+Oa4m4Qyo2mySFQHZb07q/lLYiupUAUD+cHFF9KFOBxVZnQ6sRqfDXgjQNSXfTmvIc9SEfePy/wOuguuvdYfN8dk33vH/
# DATA VtT/7t6+jf+q/zn/3lxdvXX71vv6GT1fXX3//TvfiFa+8TX8bwbYEar5b/zr/J+fe+38OqmnrrdW69dR1Lje2ju/3u9db11HwW6q
# DATA 6IM6Ktfr1zFLhXr8+m/f/OTNX7z+4s2fvf7l61+9+bM3P33zk9c/j15/Eb3+nfrrt2/+VD1TT15/CX+9/vz1b9XHQuCBKv5P9fqf
# DATA Xv+9KvyTkq/qkfr3L1QLv3nz16rI61/DK9WoKqqq/BW0pv7vV+rpr9/8THXjp+rfv1EfUo2q+G/f/JV6+YvXXzRV86jCut46v65z
# DATA qKhO3L/WGyEMBCa9ePD8+fA+/BENlITVfv78ejZU/3lw/zhLew/un2TTFDMU5dkUXqL2DN/jGzi08PhlPzsFWCT1p9agwePTfm96
# DATA 3O4pqbKbNfBHXVsCGrkS9rL2qq3reDodN4C+v4RPH1ItjR3IW9afnjWejgb97pnXAAthjXzSjZ7HeTY4fB7fi2jK/YfTs0HmPeuf
# DATA HDlP0FWudS8aHfxALT+/GiqmBYUP0jxrqL6IRwDK0iAxyz4tzo7YBF7/16KX/XyGUu80OxiNXkSYrkZJuUfHcCc5VozkeDTo5cgK
# DATA p8dKMk4VW4zyExCc6TIBCZUj0Har54otnURZmoN5YjoCptiMdqaz3hl+O5r0+kOAXWIkWSXQgUh9AoCQ2Gvc6g+egmobxJtD8B6J
# DATA fhz9u1k/m0YvRwMl+t1fpkL30V9nkg1gGP0ujUx19xB+L6e52i/5Mjxv5i+P4B3KlFD2RFW/rB6+9+pkgK3KmnCV8uMsm4bqgyVo
# DATA dvP8kp+hnU9/RksBEPqFIj+AEiDYZ5MH95epoPoDTwIcE0j3h1sElUDwuSQVWLs6LANVJfbpRX8se/NNYF9QaEe9gNXhfXB/OaXT
# DATA Bq2K7w/gYuEMx5r2oBp3VVQdw/SlklH6aWOQHtC0PAG5ST3uH6W8+aCFkvq2XmYTOMdYlyiVq/3Tz3JTbmecwgGO+LlfHLagKbsN
# DATA +/F0NHmBa4NFl1V/eFJhwCQa9uBTPT/3OTWTnYox2HrgC6JMqw92j1O1hGOQiU1Am9ri6m8lqw2bqvrVB/fHqlgWwbfqeJxFx+lL
# DATA 9cfoJWh3IfPfMR4ASOWIr2E1UMyEnTpqRupbdW1GdzgliavTNoUjdjaawdLBx1pRpY+uanX84H6v/9L2m0hD7u+Mg9l06h0Ydyk+
# DATA UEKmbuYgU/dewNvlifZqAfPgaNhTp9qpb5FFW1Z9hX1Osx2Ydn5Ak37zwdYkGvdVx2ZjNUmKtBzO1KSMRgOY7psw3Q/TQXeG5sjD
# DATA wQil/ywl/+4IqX3Um6SnQHHArw9mWK2X2RxRb5TRUvayKaAVqhuEkl1ncLZUx8Hui8A1CGTUHSkRvQ9KcJr1y+w/M95l2HAP7h8q
# DATA UR524tg9UWp3yakArS/dEqBemztK1acKPtBr73TFJiKDb9aQsv9RejK+B/L6y7R7Bh2K/t9/ii7Vf1o13etlIEpwnpiXK6Zvm/0D
# DATA t/8Dt5/H7WlbXoHJv2MefzUWP5/D/w/E4N8xf1+IvV+Ou38tzJ12pBy+Yej/ck4QEvz5vFNR+lGeaQ66ptkmqfNUi8jdNf+UQwa5
# DATA JrXDHB1yAKQau9pWqFbhJeIp6PYnyHxRgedNBE4PijSaBeeoThtk6QSh/E8U01Y7a1BHBqwG0T/JetHBrD+YwgiAPuY0ZNXTZzl8
# DATA gtKW7p8eAbRgOXpXywO5LxCQODAaDs6a0cZUy3BdyPMNHB8mTrEt1DRbs7YWBdIecBhUL2IXYVEaKBbAWc9zxDGKdrLsRfRDtVfA
# DATA WUsbF46zwRh1VdDJKD08hFUCgSQ9zKZnZoSfjWYTy6N5aErSyaPJbGhEzQNwdsomzWidEw3BlMI4ZmOQVkDO1LsQ9niOMowqACkU
# DATA RiAkKfKQQ5l0cDbtd1G6UWPLJlOw8R+pIaTgf6Fd26Cu7nHWfYEqTzTtoNrT6cx//8n/lvNYQcuLfkF5dzRW9aA8KdasGT2E9Y/Q
# DATA Lo+IF2pgZzByrgu+gK7+f+y9a5Mjx5nf+1XKodWyWwQwqMK9mzPy8CbRS1I0hxLDIepFASg0SgOgwCqge1qzE6HL7soObRw5fCLO
# DATA RjjCdjjinPeUVrRpSqIi7C/Q/RX2k5zn/zyZWVmFS6N7untuKZFsoFCVlfd88snM/+8Yr4imVFIjHSh7XKmthzH1RZOownYgKCYw
# DATA lCVvZ3nMqU0suLDpGbrD5IjHBwNUxZrfezs5mYmZh4yUnWUDqjHYsVaKmtRTuSWDEU5RpVaOHm4QSUUfJ5kULfYUpmziP4yied6o
# DATA w8EAtv8kQWMYDPj6EQKKoZAI4SXOTBo9EE5W8z5M+L4llxrdHqVcZMhL06IQ6BwRHke6k6Dq8wF6m3ghSaCg7eZCObakys3VXLVW
# DATA 3SqjR2QsIoknFJjJihFPXgoF+R7F2GxcyiDugd14Q+lgPBwvoRJKY32udBgiijXvTXQ+svcARZJiXIyob1HVld6D81v8m1QpZe1f
# DATA eZqz22Cz0wxnRzP51oz9q9j612DqF40msve/87ifPCLz5WfA1/S5llbpyhM89JgsnmQyqfYjmgvHSXqQTSno8ROE+3gaplQbDuqH
# DATA WOE4SuH6OTgO071qdR7Oo3T/cJBM6BG5RHbZ/iH6rwO/M390x6+1W578grD2D7HLnLr8k+pJGs4P+lQDH1YpbcMn4WMJJp5RA4kX
# DATA h9D2ry6xdZRsvaiajEaUoINaEETTJ+HBGOE85nuGYIFwI6lS5R88nFHbPQjmj55IJanEs/lyUZH9WxU8gbHmMUdRvUvfWZO/j4dx
# DATA RsPwKf3Mrx5NokeHNFoczaq85e9gEAETffhTap3x6LSq2pe+TPNTMlowrh40m/NHh3MxDg4oJ6jP9Pyaj7+HUgIH/vyRl9GUZuhZ
# DATA +beS0eg8ZotiTlN69WVVmmk4jJeZ+lm+VCgGUh7VE4lTu1U/pKlURuHME+ZdH5ay8QATGJUnNdPEdO7kVx5b0aRuapbJjqmV6qCC
# DATA +jFbqNjLnUXDu1h0/snjlYRy8u0ApIqpIA6oZDCqDB8n83BAs8GDWqulU6PmgFQ5RmQgZFWyB2OMQOrR4kWuFKVrUkVKF3WFKd+7
# DATA nFKzOC1efUxNGzXmoFEqVL6L6r78rOsyFc0TiQf113s/5ikSD+PUKn+yb11EUSY/2V+pwzyTPvDr9W8XKl2bKt2G2oXX7+/ejvOq
# DATA i5pb61gVV1e2hk5EKf4V66LEX0U3oKZ5qKLKn6USV1c7EWp21Wyc0peD+pNCcGSr/+Sxjlz9ickQKxf8bp3CpsoW/yw6YMuJhqkn
# DATA PD8y7fsojYeHR9QN1RqcskIzqdfl7honyTyzqTPgYDoIpdz+7VCbFOoI1AUq/8dby0inzq8FLR2qZCDFKzqiUfyxHXCnXjeP1L1a
# DATA kx55MvYr46AyblTmqguvLpI5PT72pfeT12F+BTNZAqqAtIzxbjrfC2pNvLrSrrWOTyqtGr7sU49eb6qYqjzZP5yQJURVAm5XREB+
# DATA pS6ByRqVaq3eaNGjh9PwkUqD3x6MD1Wk+gm1zykltMGRDnaLnC/daaVBUQs44xE1v3tB1CguQQvZWXw3v7khb6aXeCrXKcRGOcDi
# DATA k9wyniCDddLancH4STw9qmTHR6bWMAnt0GqvqoKEy0XyRObEFd5nICO6airAxflBnSpyBROmPTzpVb02+nQTERmk7JAurKvlgYvd
# DATA 5TT2L06iaMY12a+1SlXZr7dMt2KybV3NfVJj74XkZUfysil5Gazmpc61oE4VYu04RHOJYoK4X2DrAf+RhheooZX/PmF3yIW5UG6n
# DATA m97uhTJyKa/+XZjAPymbHgfGUjksNcsnNXiDHkM8gW8cxY+i4eHPquyDoXQfolFWfZTyIYgblNPI6A1dtOkWkE4OWYagxwgFTz6p
# DATA kUmT6M6xKszANsqu2OvRf8yeNfS9y+ksO/BHqUf/burfuIFy+F6NLAd6DaeVu1ht1uRF2mxRQ5C7R/HRMo2MIZlfHYTsDbXCqXWD
# DATA NG+fSFWty69VU4mL60K39LwvbbSmDP5S1rTqebXmu9fXafUwd0jFKOzcmOxMpe57pftr2bHkF3nUGRbvoqxDyT3eoSzTaE6zwr1G
# DATA heo5FcpevUIlS91GHqMntUGYDh9bI4s16rR5qC/XwmyZjnCE+wL7Yrs5Ku/15geY/VcH43gyXE0m31KD+7xSmy5pUvrYNhD4CgWE
# DATA 3+3K05M8PMG2fNsa6K1tU+vN5xZ1sk36t0H/tmFalcqJ62ehANhnV2wuGwx1M8AgkFJvKGk+mC3Gkid7wWzf02nZVBLBqtX2pGb8
# DATA puW6Tt0AJQudhLnFU9aAZKAZ+DG0YtTHB4QIX6U1yHW6aNt81bMHv04d1yk98WKXOkqZqXoc3b0UWglDbZ7U4Fsw1l5wk/USb+LF
# DATA nFUTUY8tNTHfLtECg7UtkMOSzYCPC52VmHt2P++pOrelDqiU8fjRXDejtNpCQ7qjkzEflkRvdUCTMu5FdYwOKCmLU5NGHglrsm29
# DATA YGPXWtpqVs0vkG5F+yLXWNpNO3X1Q9xV5QUc9ZbcjzmJH+9gbpTmKNRz0LwpHkSP7Swpz8d0c9TNQ8bdmhQKTS+PLCPKRL2+wzAh
# DATA z3ohphs0H9yhkhTqhme+BfgGm261QdhjSrG/9uq7GWjFWHpza2BWP2U0uM+OHpf8BtRAwqOyd0RM2y110xRQIJPItFhnuu3VSeWG
# DATA ptkPS7atbkkrY2vJLih34WIQqCA9mRTikQPfmmf5Te4ppSnkGV123gzDbBwVM/jH43g4jGY/KTSgfyV4wHC2eELN7bHxgz1i092e
# DATA G2F+kL+veUHTt7Oyu6lhl9xu4ez0BG7oJ1gbkVIehdN4cnrwFplYCY3Llc9eez/u673vHySz5LPXKlP6w+EW2zzl5ZDG4XiSWdkU
# DATA 7F4flS/lcckrVXZalex1/U6vMLvlJqwmURc118Pi6MgxDtTEJw+xYQ/364zOHQzAcpXv5rG0Wp9VB1oYX9UNBbcGz1R2809Sj517
# DATA q0sz0Q3VoTaPJ5NqmpxcbGUrm3oRzU2p6260mf+ETty0/6bqoBdw4XF45VbwhH/SBUdd5CScZ2SVqA/2BNqugTwwL8aVxVCmZZwX
# DATA B4hNYRzdqTIuttlaT2oUg+gx9+TSgR/4d6o+j42Wj8gyGsRmSJaL+XLBJxLKmSVzKt6lX8WyzRprFsfTwkWSPtbD7jpbVmq07uhM
# DATA hX7yr6fRMA73LBOtTd3a/uONTgfb09Boo+9VXoVia1E2yeroxJVFTlFguivZZNcZnp9unH+WGmUDM1c7K4vzSeN0aXFfzXOjSxlj
# DATA 2ljdHB/75eunkA0sNhRniDtmy4rBsHlaHoy0j7FlWSn6wXv2XMqunkHJfNZm7Gq9aDa4XnAeVrSVuzE+7JYR1wuP6r28cAoTikDc
# DATA dGqqWRwedk/9zsnlTmTN/Ic7cqpKJt1zXtLMqmk0XA6iYXWacLHIV2od69bEOPDvVL5zIJs+6EM4QrsJZ/E0dxnl4/whL4rEa37R
# DATA 0ZDTObotSjOs6MWossND7GMuTWV+WC5fWamzegW2AtTcsE/z04dmtlG+6cmTwoqh3rWFHYL0x3s0ncx47RP78g7u3Dk5OamdNGpJ
# DATA enQnqNfrd9QGL2wgejN5hBvrXt1rN+kfXvZFjfdkAyB954uedGT595Sf8wN8HtEQxHumGvXGsNnDxsd7b7BcCe8W+sBve35v3AiO
# DATA u98Pmsd+fUz/7X7fb/+s8PAoGDVGDXkYUSyuimY0QkZPn8guTeRpMs8pSCZqfxvfmG/GoorbP8UvvG8u312nNj+Zq/ai80G+o8fs
# DATA AYiGvBZ+ajbgWVnSq3vNZstr9Jpe0KpPGvXA87uNaqPe8fxmo5gxw/awH9VXc7XT8Brdxo/8TnsSBH611/ICnx6vd4/p7/sIulUP
# DATA ikFFo5HPeczThYec/m81W616K8ovVk3RN1ZeilC7/nEz8Kf1auA38cpqr8eRURHxfKkVV3xDENS9oOkf+0Fj4vu+1+r+KOh1f/ZB
# DATA s9HzGj5Vn6A78eudarPzo6DdLSavO+hFYbgSZKdFudIb+0F9Wm3X6Z9jfGzS5UazO/Z9utxq0T/H9LEU8367X2+O1sW8ubGmqu2L
# DATA VFEPcLLwsfIEH6gafsjz+wPVWA711PbgW+1Wu9/ABeN9okf4f4fGoFm9Ehx8K/KjVtQ5VD62g2+1eu1Op3UoFsbBt/qjQXeAJ9jt
# DATA TD8P241geCjL+wefvfYgOkoi74fv0XThk3BMtmflPm8fy6grrGZRGuNZ3aXtdDu6pxp2W5LJlHfpB2JNekHR6dwVQ8DcbkYjNb/5
# DATA XkRtOg4rEnRpae6w7AiDcVbp1JrHJ5WOOMI4YLVTbpfp/Vb/Fs1UiyGWHeW2macKZvUB7UMvjhOFu+YFq1JMTr4B488gxk6ix5dY
# DATA HsjXAsQDWDKLxGlVv5xx48FFW96IUfQK1Dcas4XUVlaSdpFxpzx7K3WMzYabtFSerLb1n6Kpf/Yadu9RJxEPFryTfMYbIL2/gr6Y
# DATA d/ee2QJZ+3wZpacPeF9Aku5l+9a95ub7aRqe1kZpMt1b/9z9yYQetZ5Ve/n+JjqF9KJ+Bi28hu2AFFueW3qve5+9dmBHcBpNcTpb
# DATA sGMfhPM9DtSwwlnO+GF0WvFG4WSCyr3vPcaBf/qvBCAy+byn7IFEAkTq9yir96xIvQ6Nsv1DQxVmugq9dDmZeN/19iQWtXGY4WX7
# DATA dEldoaDkyoEVgQMPRz9Fi4DF9g+9JziqPBhTrNQbLhMiHn9ip5oP1UuyFSr2sX48k8f1D4cqLwrpzzakvyLxRi2ZHcWjU42tMtmC
# DATA LTZr0jLC4e7VSIane5g875uiiCBQ+1d7n732LfH8fvYaBQ2xoWgCRGsNd6vTGXQjvh2WghwnJxvDFGP00mHOltO9eLifp+bD5bQf
# DATA pXsc5mcQ/aNfazo3C48O1SbSPZFzQ+CiZ0Fv+uw1fL1DzTmeHepjLnLG5bU89ssU0f/hx+/XZMflD/h4CH2Hepv3JjT0foxwflLx
# DATA HiPgJygMeTS0G5I8/c4kYr2Mz14LORvCGnb/QbMmneCbji9aE8UYlwaTePCQ2hS2nn4ST6Nkudjb20cbR6TS6JiMijxSFA6472S/
# DATA qqyQqGB9Q5cCZhN4uZ1PyQwbmvdGMyQcZYMHWAhvCqGPd44p0u8rrRUKI1v2pzEVZMWLjrnY7tFj/LEG1Rj6+7ZszNpTRc0B0XSc
# DATA pkI/Ar0jXpzu7VP4M9zwREX1rxC9H8uBi/A4+glFskYPvhMOxntq8ye/aEJGcxaKGB33LhQhfEV8fvwT9cZ/JT1gnPHfPb6B3qif
# DATA +/FPdClR/mN3PHQ59yV8uX7KSpZ8f41GlclyGGUqGnmHSL/S+8wmucV9LW2PEra2viFqD7jR7p1CrdM8U6z8eOd3qWI+kORQByOf
# DATA cd7oyaGO6l7++Jqy4fqC9+nkXEdW6c87ZAclQO4io5qmtnvHiAXYwXe9tbcfeD+u1fjzsLLuDlNQZAFnSCbHg7tXKzES6UIWoXfL
# DATA nzHZavahL+dDvZm8sIFf5fubatv7+j3uh/KMhMVb2jO1nR1nQsmgOI5q3MKfyL/F6m0WvIp1PHmUV3C+JdPFRj+ZTDEPby5CeZjK
# DATA 0ISCQkQgKzbAZ6+t28lnR4t/l4jxR4kAF4MEn9cH+V33xPJtXRXlkzd2HVUmSK6Ra9kv26J9oOLyGSQ8p2R7SG0zUdhUczbkp46A
# DATA qj36K9l3syOaDML08diM98x76WKplunWsqFeHZoDFetrFqpNXm9U3dH5A3PVjND8TfXkcgON+jS3YmOMb9Hfy929NM33RMvUZD9n
# DATA MusTc8jflVz0/vZvKdaoENR/TffoT/J+chKlb1Hm7ZkspoaQsfiafmXhabKSkHCu1zgxQffVDz2rQSBTi5WOLthVg0UXId5D1+1O
# DATA sxibvCZyWva9v/5rb09H7e5dHRNEigMyVcDk2927Kimov7hFlvXozf+KoyDNjT/uS1pef10KShk7WDnU2c9fcnMH3/bljjxYyQ/0
# DATA jvV8RFJKRVKGuMEEIr/tq3tKw4eExbWUYxhlPHBQyesSXdMYuR2hLVqVAskx5bi1ARceohchjqqaUibrQPaLNQ43Kotjb//uPbYZ
# DATA P3vtXXMoDM3k9T2YfZ+9Jk2P0v8d+c5zQG7ui+RdbKvbC/ZfR4L/9+9rn9H/Zm/rWXKSLNjV6oULz6cZy+sSAB82owDoofXvIePp
# DATA TvHW/F0+v+v//JP1oI7QDs8NptK4ZQaYH8h0B7PdweyLDma7A9kv9YFsr7DdWJ2Dfq4PahvPGf9cOAE4sY5vP5izWh5GtngI2Ig+
# DATA vZ3fztuK+Zzc83We+0U51XiRcIvtKOX4i8f53hvU05aboV4kQzTMSkVX1rusFTy5EE74W/GgennxSpr0IEHmyptOZwMdDeXHvveD
# DATA lbUvNlPJHigd/Lee4S+cDs6A+T0u2gMqd+jBUHnBHkoXp9hUbJ6fi25ANg75RKyuUZ7acEHTQj6OvOzTuObBq+thDkJhfs7x4F1K
# DATA cZLWvB/Moxmf8x3x2X16SB3m58rqUVhj1Dqqk55sQ2AME+6mN4OxQAHNlG7Ajso7XsnHrXUE+DwxR5usBTKyj3Auzcjw/A2OOaPC
# DATA 4XQ3Ex28j5bG3evNcJnVj+QdMf20nMNsyGoebCn+MWOTKhnByUMtZghLTTUbMpcTlgAYLVOyIparaggv52FbE4Kz3pz1dpH1Vqxh
# DATA Tl/H6etc1mzbaCDelO7OA2xhs+Qg8Br4NiGcZxR4np3G27bhErv7PFuurmDJ8foH2x9YFFFbcvQ1Lmx0QmLHsk9AZ7LyAu5N998Q
# DATA n6hugDNej0IhSWjmOdNd5VfYK8bbP2ot3kSkNawp+bwhChenIe83aqnNJNGcdx/VpGe/w3EsRVW8EKY64NsOEdVPmXiaCyaajVr7
# DATA GqMpnhH6WXtp+MIb4mhVkdL3mEiZh95IuMPPIxfgzff8g6D+xp1EWYXle1rqntaWe/y6uok+5HfdkWjlSVG2us5NtQpGD+bNYGFL
# DATA HpHZwE+wIZFO6b28J1ilU62GYvTSVTO/JD1PfMwvmtM4vZAcuCNBYP6kckvWae1Q8kt6h5q5cs8yOENMyKwOwJamYqNRmv2SUgXh
# DATA F2NQfkCDIfXPYjRqr7XV/jHGRjNu+WwomoE2TsWOrHn3h0OPz8QqsyDTw2duQ3rvYw1FqXpiImBG2iVk08XRy0apGOLU4+CN2IVB
# DATA b5svJxP+cYllWBrU41Qb/z/MIlHeEREb0f2J+zFlsUjMaxEpXeexYJtxFMgsgWHBpjR6Isxr4gzTQkrSTDo/rXLF9voEwvdWL4cx
# DATA sB+xXiZnGnfwUiRcGi+/1WwPgM5wdobzRYZzyUBylrOznLebw8+BYuUn9DZuHJlo5oVD1Rpys7mk2YjBxei8sSLiw2hBBTo7Emm7
# DATA ovSiMMGSEcatRElA5kqJoodYNpJL/llsV5RSUFsW3xg3WH9OCznrxk4xbojLzIhUwoLBPiXoLYYSXRbDTkYjbP+CTB/3BZk3Tk7o
# DATA Z49KSIZLzuuap4wLSFpS7I4x7qKfSUbcMXCeW/KV4rPi5BQHvUXI3sz7KYariRnpTIrspL3PTrlwQDYOhDRPqMfKU4aRt8pTBtkQ
# DATA zajTcJLxdjFYOkjiEdlime7VhlR4Y+rNuJQ4mXLKh0KYsag43IhkOh3J3EmMGO0vS6ZkNS6UumAIq+Chp5VCtqTz7fCUe+LtCUUZ
# DATA iqsSZazT+ED5H0dRRMkaxiOW9qPZHQw1CBxiDyP2IVC1WsgWDKYb0y9oiviFTUDvE8bweMwXRIBsWTFTFo5Bqoo6Icai6y9PpVKf
# DATA LlCfsUl0SyI/jrI1CRSzolCFVwVVTVUnK5X9lidQhUclm6AJ8qiTRuuMWBRpRduRILyFwxhn72SgEztViUlS7f0Y+i9DykSyC9n2
# DATA Q/Jh5y3JmOAnHorHVbuUGVKG2j2Vd4o9qafSWup0FKdTXhxZN7flRH1CeSPzcTB65zhGSmaSUVunFmSs53zxOxP/tdxP+cHVkUwB
# DATA NT0PM7GFuXfyPtDintS7MuyBTWkF4jY+ZGo8D9k8xtSADF8q6XC5iNFthCnrdE2V8iSrn0qHAi6UuI3JQsB1NaXYmNq/mSUnUj/R
# DATA SqiJoI+EYKtO8NsJh7/AvkrktrRFStAcrgTuGnlsE7vE8iug8VMpY0tDPDFwrZSnCykVN2Uf2UiUYZJCKnIckMaOjHBFQbbQDfMU
# DATA YXZaVpM18wlbVtay88Vmfgmt/SdPKoahszgCnDc9tQk6/9/5r87+cPbN2f84+1Ixcr48+zP9/4vz33pn/wymDf3wc/r3t6vonP9K
# DATA P3xFN32F+xl+8+fz35x96dGX3xmIztcUqFzmrwDt/PL8NxXv/O/oOXoGt4Ge8w296Y+M8fkH+kGYOn88++r81zoyf6Fb/iCgHsB2
# DATA HEvnBZjNoFPG8SXqcPr0Z1EQzT6KEgonjQfaBKt57zyaT2R8nnCPGEnfkI3jOfUWE8sboTtHrCLOo9xnkM+FkslEjU/0Ui3zuxWq
# DATA g+VEFZ5qKQ6tU5zf6B7ktsE660rm5vA6edUxt8Kkyy+XH5iI3rS5+335ziP6NRN2eFxTw3qiNrdiMHWAnR2L7foRO1h7j9j6ROFU
# DATA chcjG7/IPThksigqGKZjGk84H1luP1tgplrarayRmgjCHEqJFyt8nYur32aH5pqW9awwOxcnw3F2nCVwE5aABu5c0QB4RZybtzb4
# DATA 38jYv9PQf9mR/3YGfqmeq/mQM3iev9Z1EzAeKwcYxVN89Zr0roI86HXTuVpJVIVHeZbipQp8E0nWZCpvKp6SwPbS8eliPOVQ5IAJ
# DATA Z9CuCB5VZPlCJHXEE8bLLLFSC5X0BXJ7ofyzckxuFB4nGBUUa0bHGC8QuAkPp/SgthjUubrD3F4QYhF8PzAjTsLZwnaLDZK5Y+w4
# DATA xo5j7NwkY2fXUWWnac6uVvItm/xXsfivw+B3tB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H
# DATA 23G0HUfbcbQdR9txtB1H23G0HUfbeZ5oO0ErvCptpzNqjQYvEG1nde15J+YO567KPezK9Phd7XZBIa3VLOV6s90tcnOiqDtSYCMc
# DATA bqToDTjQRptlQAYcaiDBsFSG32wXIT4NyvA1aKRO02sGdQ90G7/Vm/jduhe0S9Sett9qdfurpJxmw2v6vR/5vea42T0OgtbU7/he
# DATA /Ud+vTFudo4bfjEKg2DY7PfXJKLVreeJ8IOeSUSjGEDQC4atVWIPZazX7ARjlYsWPcc8sELPaV+BnsM11qLnUOUv0HNazW54FXpO
# DATA axiN/Jye0w7afmdo6DmDbn807OX0nHa75Xdvnp6j6niVq7EZFxpC0NHDbeGmdY6qBo8jld7xSaXLllRhjak1GB/uTNopv005uG3X
# DATA lpgY6i4cLbge3I4d4ipuR000u8ZYRRkf8k6OcThMTg7qHrwbdU+XZAHQw+169RXa7W5M846snxRyvXRTYa1MhvMSDOdww36A1dFK
# DATA UZLWeWpl3XZLyKqrUUObbih5zWia+F3sSlV9xmaKT6G0L7ARC5lnF6ZKjJ68wApxlB1H2XGUHUfZcZQdR9lxlB1H2XGUHUfZcZQd
# DATA R9l5tSg78UjsN6x7oMY/tr9J3bmrRkw1cMlvFa6L+4dPLEzPY8k3ZMZdDganjkwwr9MTwO989trrq+9QlfpQDyjqJas35reoAxp0
# DATA F9u5hwoS9CGOcUnLZ1N+csqnc/Rby1Gqef9OnYG3DqXxwTOUNVUoE4WqvoF++O62Ef+assLYzCapvDhVWzxa5Gmm3vGz1963Tt6Z
# DATA ZFB3qVIgE93SOR93BN0dQd/5CHrxQJg7i+7Ooq+eGtyot/k8nFEv1fFCa7HFadjzxwK0qMxZrpaihG/jYRRmBXQLn4iGsiXIRTzS
# DATA ZNSdyTlhraTCW+lKp2V3PYPOSWB9RozlLM6nJEHpVXChzkWPr8+yi4jfmsOgapfVqn69sl1RBfmTUoNXwuH6x1zP3Fzh7baQ/4w4
# DATA HBO9OLOyerPKuzGIWRpdPhc13q07TPdpP7Wi0A6LEoc70aHJfSzuuknQXXWpHNb31OfNd8vxela540+b7+Q+V8nMDqLN90m/zenn
# DATA T1tE5eWgqZZzFzvUVnPHELNFy71QE+A/t2Vd81/greeuTs8D5JPO83KelcQ22a1vegGxqrnmpUvOjX/5p/9o0lGOuJX/c5YoRZ8z
# DATA Cee5/qpaSuQ9aekSEgmw0RKWYphBCZ61qKFWGlMtZChTOJ9TnWR9XeqY0fpoEjtbyPF/6LEuoH+kdWhZq5oXP7TI7AlVbnVYXPm8
# DATA 7JaZn3zWTSM/WG0cZ7iskmJyRh+9pAvsC+aaQvdaIICyauuliiivqJctoL//75sLSFd6KZ73UAxUkTNdQJ+cJNRGU+rYPH3KL1Mm
# DATA CPVJyxk8kTQkzWveezTKw8iZJsciSEFpYMEBCBscRdytooBk/7Aqp0irW6jSevpSMSm4tXIx3cJli+Uf/+vmYlFdjJSKyIEOkpQm
# DATA I6blzNREWC7zNKfPmq6sqyyfvHmIhjUU00EUfEfUhycnqoiKdiRLs7NZXBgHrcvxAkb005eSnaJbK6i8X750D/fbzSWl+3gpqk/D
# DATA dOrx7q68izvBNYHjDI+hhU0lc0QFw+sX6OsiGe5nQ5HSiFg9FjrT0QwQHCkBNRvoR0zuiBeiyYHdsfbPTJ14+vLJk3FrpfM0I9D/
# DATA 88+7j0BvYZCNUhkSLB3wKdvVFK/0obK0uUmFE1YvD73pksafSZhin9wc8snIaO9HYjyqAYZMJDAMpNmgxJ++JArRfRGayn/atak8
# DATA SEYLr49qH6J08m4NY3yfsmgKLRtoxgxo5MHkgBWhw+FPQ+zPUTU+Q2GlbI/H03iC8wbIKahUkKX++TIWtRqoILKwihSgVoS+hqZS
# DATA SMaVCqhoBIpH0zYCzRXJ7nsfJtr3qDWFePahfIJJKlRGDNAJd+K6YJXwz9Owg14NcRcH53autCu40pzn7BXxnF2W1/1cqDsW9l9u
# DATA x3bLnJsG0gW2apJFecROrY3k7udUBfIFEk27SBva3vd4ExTv1VZy7SzvtTKim4jeqylXtxl1bHG+YBJU83wjic3OpIr4jkQN8iQx
# DATA jovcyaSofcohPAWU28j85QVd8ZaZ4EshC0jBYGeEJCEra2GvqTVKn5vrZK6neSUt8A/h6ZodARoogHHR7TFS4JayoAbfKM2sAyMn
# DATA CrM6FxW1lUQ99pmQxbqQ0sK8B9a3h4240Ns8LtQH2cwmmcXbVaGJOssbvGgX6txCDtdeJePRDsKZj8583Nl8tOuaW4d167BPaTVu
# DATA NFJvZh32A+F+2krROfHw2ZAqboMSznt/UL342GBhmVP9lOO11a0r64X5QlK+PLZpbdFe3rBXazbdX3K0l5YSNj1VcP8WfNqbnii7
# DATA Kctu1k3Plb1nZa/gxpXTQinwJivEFNVpGA+5PshC03ff0PKVqljUveCXy55TYYmrc6aadF5eBMchc83fsy0qT3PvqVO3bSpxmelX
# DATA 70AR500F09NCA3pxEeJYaFowCXWOnj5Tlmoysd8SzfV4IjNONsEjPZMyEElqP2a1asmmAoVGz+C5t3VHgr7FHp49JRDCEwBjsqun
# DATA PoUlLn2PrDsOxbXM+8opJhDuxgKNeuJOslpw+bxxvdM4r2v53kJwPHUfRSVdKuGLGeAvj5VswQFZCimZFtiA/1FB/L45+zP9+6ez
# DATA r4Dh+8rDN8byfQPW35/PvgSUb5UO+N/P/sLEv9+ru786+9pjUODvzv54/n+d/eHsi/Nf0rN/VIF+rRCCX5//Ctfot2/Of+7RFxAJ
# DATA BQQIMiHiIM8BWMjcwL84GOCLYPUX+u5RdEK2A0+i5yGkaxUEAL36dAT5iD4kuzQGhDo+rMreV1jdpM/MA9U993Wnpfvs5ZxfgybE
# DATA 4ZGRMRD/SbRYzrciAO9D6sIbLjNsdqH27ACABXtf9xK3zf9bLZabo/+xhcWElfzWQn0r88zvRKfRPI7I2tD3v6MueFAZAkI7Sa8Z
# DATA A8jqYYyEXi54/FdntKiJORLgrkV4/ShA6muwCE5tfhaP0OkwDJ4hztgulyaPoKET8dllMeVhsKIWUuc2WGALw5Kl/+XHTG0+0XtP
# DATA dEUTlypZ4sy4wTQuPpqtYAF3r5abbZ2Vhves4IC7J8ZBAp2FcH0WgkYDXskweDWcgLdmFNyATbCTSXBpi+B2DQKpouXsMGbAc9Oq
# DATA bgIJaKVaLX9tiKKGi7H74uGpd5SGw2WooH9ZvvoAGcPiGhujBouLEqey6RNL88fsesJaG8siZvNogJHfmGI7wQHNuM7K3JTgTPbR
# DATA UQaOgC/jClhNRlVUTu5nqQ7VPKjY4vhsKJYDfHRMwFNxUGw1JH+e0qWM11JVaSvzTRYJObJ8o8m+mvdhBICcXJBNew+WMEPSZHk0
# DATA 9pYzKqaFnGHnF2cOI+gwgg4jeIMYwZ2HoZ0mSZc1qG91jnCVKcJ1zhAcVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBR
# DATA BR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFnxuqYNSJhiP/ilRBvxtEzfAFogqWV6B3YgoW4Xm9pgXP69QNPK9T
# DATA zNfhIGoOR2voe+3Apu81c/peu7cxb/OCmfr1rhf4Hc/3m1634/VaVb8VeH7Tp/Kiq0HH63ZLWL5Ou9ftd9dh+QpR5n2Yq/GlF1rI
# DATA Q79j4tsqAibrUXvQWfN8EAT58416jkzs7vZ8Q16p8qsV5Pm12/PNlhX/hpXfO76/1bWQj81G57Lv99t2eft5/Bs7xt+uL1K2/Hhz
# DATA t8fbHTv5Nuxxx+yXR1Ty273Lvr+Ye/UdXn8ZSKQ0Eg2JlL7MgkQOOuGw4xchkeYRA4kM6o1+q1eARAb9ZqfdyiGRg/qwPhwZSGRz
# DATA 0O52mzkkcuQP293RjUMiZ+jPq9nD03ydQ45QHkfXsO4QWK4ObXOx/WBeqy3CgukjL6PZDKb1a/awqAy3g6lBu6ho31uh2HdqK2c3
# DATA YmUhonrRQ3ERpQT1PSpLHu+aa7W2RTX07GxRt3l6V0sxb/SsFfvkC47WEtBxyw4FtR9B0lHN6IdpdADRy82URpMPlVJyt5h+5UKu
# DATA bC0vdqaYIhN7cKWaiPkU7JJTHIKjQDoKpKNAOgqko0A6CqSjQDoKpKNAOgqko0A6CuQrRoFchThOw6O7MPWoV8cZM0ryHfmqT7Ig
# DATA ExRy8QNbUQCt6nV6murCu9gQuefvv/7Za//nn2pMPLy/VmeAn9mT8MO5HDbAGymYfRNOgHD+9xcSzlto8Xx8aRrOlqOQdfrlVJec
# DATA R6TmPJejbzhUFQpyIXpEN/LhTzIHMhraCoTEwhkdd/renb6/4PT9miNc7iy+O4v/NGfxN+px3ugZfVFETPggcn7cW4aV7xp9zmcv
# DATA H3MbWp0y2kFG1URhxAdkldW5N53uK0qibqEzdoDkgn46CNOtmQtG0bLTKipJTuOZrHvVleokrwIpvUnst+FfN/MUzaBsV5XLxtsK
# DATA xETdvmZiH7TWRT6wot4tRLxea22Ouhnv7ajri6oe7Q2jozSiqfoFKbDCMimwr5kUtNdmf8POfT/YkvkbFTp1K0GNlg7iRVXntEZc
# DATA 5iHSnam0Zn3EvWD2Yd60WN9k6FUxjqz3T/NGbt/AIvsiny/FHWUL6UrkScEzmiqRh8E3908F5Vjol7TuAOtX6NCoHyEjUBmImO/N
# DATA xWwYxpj78WPQEGZJjZPwVAYeKU4e+zMtrHG0DGnEWUQRS4MrYYvPqYMj8wtH65UoyJoY7SDg+fIdWC+Nis6ydpb1BZZ1yWhyVrWz
# DATA qgtW9Wa20vOkfFVsBaHJLyN+9UPw94zaEVaxc60j1pOBS7xi9JsEXRxN42zOEjTeJ4auwsY76+ZE8MydRExmrXh6zwZGpWiOZfyU
# DATA HkH9KVvURYLjitiVuY+G/ndjJX00TtL4Z4mRvFEK/qGXhSPwdaKUjCKWYDKlks2TXCGdJYpYNErNIqIwO+WRd5xMI4jy8GyC7L6K
# DATA cDJEigf30mhNA2sME4I7q4xyC6sISg0cWxU2TBkKts0w0nF/H8I8xQ4QWyeUag94kHmHaGyi5Sxkw4bqVc17M54lqEP0jMbsakNg
# DATA Fj1asCHJSyrIINWPJhncVqqHVSaQVIEpv8wCha4zJtam7W9sMMIkOdIp/BgnmqXcpFoV5mwxFmSh/hHnYkWGuyASXpNTpZbPPX72
# DATA UGpaPm7oTZEi/5qx/usIUu2cCK1IytBTxoV5fBYMuG1k7yLblqiPRM5LWkV0qiSzMFLPp9yFSRpFFUzkZ/t5ebADMDdOw4URDMvH
# DATA I8oLqrCURplwKj0lyjLscp1gfwlXZRyhSe0KfZrBN86xeUQBLMg4jIegwda8txNukhj+jDIZROCUwThC55dasVkhILFldaHuq4lL
# DATA P1SFvbQU9M16imGSmisySJzKBS2yryZnxef5x+LUSy9OFaZVdZ4Cqf4s78uYWCA1N4faK5n9p3qfb8gTk/BUocOLpkpGPeH1vjPg
# DATA IZRxPcN4Kv3P9b4B2xTvfajHDqRpHs0G8eR638J7uN/RLUgvodk96PW+ryUAi1Fk9gxRw2NbckatrfiuO8vJjTFoX775lSPRuqnV
# DATA 7pLBbiL10k+kLouefb4khM2e3ptgmJYz+9oJpmuUji/ml04KBAXRAGY3ZFFXeAte9/nSUX4RJUR3xC14hY3l2gjP5VYlX8xko7Yy
# DATA Oc6nvRXvCArN+ZwGszAvxAQYW63MPHRAU2BbP1ZUWzFpyhalWWnuTSh5ErT9LQK6hVpL1stxdLGQNOrkNJxrkMNOZbCmRD9KI/ao
# DATA F9SwsyjLNKvwFTLdcsJVP3wYpQW81X87+xLUqfOfn/1ZMaj+wJirL87/PeOq/pd3/vfATJ39bhVu9Z9Bq2IgFThWPz//R+/s9+e/
# DATA OfvL2Zfnv6ZAv6p4Z/+TbvkTff8lvntn35jQQM3aDLz6JbhW9F/HtHoRSLZUh/E8nA1UwVgCO2TcswwRZG3FPBIM4ZqAXLnqnDAn
# DATA E5fGjJ0W3C+NFJhnKJcS9HGyv1YYedRzZOzp2oqwehMbaNFOInQWDmBlG6DSCdw2vapcIjfHroIk9LD03rXIKq5i5sa3ucLdDKyK
# DATA Rr252vSLWopNwskwPOV9hFQ/HkYOWHVRuV07p+pNNAMugXmU4qwoK9bjON6IAdty+tIj2x1aJmoVxNqCp9f7IZZ/lEbDOII3GowC
# DATA 6lOjFN6ufDlF9YvxjMyhpeSwN11m0p+JGXYqVO9BPI9WKFa71NTN9kyp6T0retUuiXDcKmcFXNkK0JiqKwz+r4Tn6ZYG/msf93ca
# DATA 9ncd9W9r0JfKWEy9GeSfVWO5CfpUMYneOJrMYZ2Q4QEEs4lcnuB0fLoYT7EiK0k/kKEWQu844bLgD0BLI1tkdZQ6TNCM3iMDPzym
# DATA cTLT2ZGKtBlvPcCabLpkLUWK/zQ2XKDt7Cm1OwIepghL1BGf6ZKBmGO/YTAXF4dlEDCeiMeCTEyIKtr/sGBe8D5AvYlCoYD4JSyg
# DATA ANQU/YM9FbDz9Br5cpFAHmrApC4HmHKAKQeYujnA1EXjyE5zmd1N3Vu02q9itF+Pze5IUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTl
# DATA SFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiT13JCk2o1mO+hckSQ1Go1aw8ELRJIqrjzvxJGyMyVo
# DATA e41O9/Nqs+p3u57falaDekB/fc+nf5o9j74Wc2gQdfuN1ioPqtfxAlCfGp5f706rfkD/NNXXEgiKMrk+6K8DQfk9CZjSH9PArdFH
# DATA DQu91Gi1raJXHCSBEhXBVVEzjFrRSkSbHd8LupTsluc3gmmjW/WbLfVtJZ5Rvz9aG8/Gav2qt7xmqzVu1/0P/GbgNbv+uKX14iwG
# DATA VqsZROuCXK2x7SbFtOH/qNec1r2gVaV//O40oNdQsXTxuRp06cvqD6WXdrvtRjDY8tLLoI6khWjUkTQ2C3XUr3f8YFhEHY34fzbq
# DATA iL6Go3oBdTTyh6O+n6OOOn3KqtCgjobhoNVr5aijbrNV91s3jjriHSZVNj1slpCKbHH26WMk9OS/1MztyYDNNJKZwTbID49c+Zt3
# DATA oA8VnHBt44STpbdVQJEV9qpDnkdY2TZHD0UPd4UTaUsjKAfgXWK83vLY9sF7I4TIKkHbF+iJCb05PaXC7aBUO6poi/mzOTmOJORI
# DATA Qo4k5EhCjiTkSEKOJORIQo4k5EhCjiTkSEKvPElopDhCfPSKElw5uTv6jlwanw5l9RCwHzJuKpn5KQvZouSrp+bqaUQ9srqs6UPv
# DATA IlwmCI1epxw6Yj7QpxRDuXhSBBGp3x9Q8Pxztvbn92YQRYKxQO/j+07X3vdJsggncr6P7/ogXIxr7DfYG71+8nr2+qm62eYM5SdZ
# DATA 3FFpd1S6eFTaOtfkDky7A9Obpfyeg4PUOJM6yqt5eOqF+L0gb75g5ROpzygBIxGOelPBz5DNm0ySk+1nfafxIz5+PE+TZKTPH0Nn
# DATA 3DRUGn+xFWWZRtlTaJvTiJieIikLyhKkTx+3vO9lyzk61WioWnScGfIRWTYKbJTSgIfaCTm9SbzAIk5Ck4eMlbAFZDJIl9P+IbRh
# DATA 4hmfx87MoeoRnL3HfH73U7hwCwomKWu6i4J2NkgSfmKwnENmW841b1PQfgs2RHoq++g8HqLypI0gsg4VQATJpTqLomGmuzNJb7ZI
# DATA xVymchwnkyGfdUXMKbE0B2Y5cJTKCL8dUZQnpywUbrLNlJ0o67BMOk6la1V0TgMmcpNkgaTTpX5yMvHCSZbwweCtEuHvUvXmpiPH
# DATA tumtUWoVHgs299na5OzSN8eZPkV/grqI7pnFfSY434t+vOaxonrekw+wISWCPHo84ZO5OBuf1by3WK2Z666nATWoDhR5hIrUhkNs
# DATA BOKwzDFEpeofLi4Sdeec4zif0EBidAWxHRXn3z0cpcHLqOmEU34dDXRcOkoSfrBcSOFiW81cnQYWnXhz3htXJrGicKFa/Awy9QzH
# DATA yYyi+UMJT/wrHCKZhhM7S2JznjtMp1fTNX9ThKiRddT4Ly1sjkZ43crmHyPzUXgjOKeld7oBQfOcbSmCRygKNkS9XI/gBjTNjTIj
# DATA GzUz1fbQzWLMuwGJ8/vc7RtbSalJ3J4S+MtzkDsPxM0o3IyiOKMoVyk3rXDTip2nDxunHzc3rXiArMhxOBIdPaV47rUBbwNRKo40
# DATA usyeL2/v6CIspn7AdFjmQk7nqF8FSFrfjPXMXXt0y/f1F2/v2xdF1n7QRLhwMad4dtfFudmyotzblaDK/kYmlEwWO8RS3Z4jXtX3
# DATA gkm1EjU7MxtFQuqWqInTk34ueCV3iKR+0MTSXMjt2lrnoogG2yK6EYQq81eMVlZLe3FpqNLU4qwodmQ0S9+lvoVah3dk5uIVr939
# DATA tmfqrTclkzrzGk11zwn80zTLp4l0dJSio+SnNDIL02/hZvGN3B3xV6XDJjNTAzmNWa02HpiuDm+MHsmaiZ4yYBkMk3qEVZIyY3ku
# DATA qy/TAraZsMrkaVmFwKQ/n5ZI7NTpg0iroO1AOX15bG9H33G293ZvvjO0X0pD+7KUnWcshMo7gPMNsqsGqA2hYdHBUHuwjV6oJGEz
# DATA heaZyqe+ELKC/N9rZhqVhF6vm2i0IpW7lme0g3ittY86l7DFtwjClUk4qhiCDltZy2ysDKxSPcVOcSlZtVv8jXHj3rtpjHUb7FJk
# DATA LyJdAqM+fgQbhr3/cp6LaYdx0dyhCSRmgdG6ZRelqilCpqJPqg4y8BYuZfIUDRialloeVWO1mOja8X6ANSvEnOy7UsxFdtcsqlDs
# DATA eP3CtAnRGNXLMopBiuNk2J5trRaxfCovPeEs4pYIo9nvGFs+1jZLmP7L8X2AlSC1QKenz1FRHDUsLuzxksnErPpRHBV8EisQWATb
# DATA HFF62bp8fWW0Oy1yEBluA3B4LHbQfzr78uyPZ9+c/+LsK0B/zv5w/huG+oAe9Atm+PycfgNd6Ler8KCVh8/+fP4b4IZ+cfaX85+f
# DATA fXH2e/rx18wg+rri0acvz76u0hNfIWiP7/mG7qF3CFpoI0yIQsdbvqA30I0OKPT8W9Q/hH4ZrxNzb6JoYacVWRDEJelo1e7UNDoC
# DATA f1nLOcvCv6qvZnBPWbS5QJmm3ngrQ+itcSiqBpZkuOMIWda16hJumyS0rlxujibEGwLGydzc+Km6sJ4pNIrzbvrdeGE8wddMExKo
# DATA MdsL4iuyiD6vOkdolxK7dprQfU/A6wCBVxfLfmRKXjz4MfbQTj3ZCV7zPkioBswMCJEK8Rh675D0wBoBa3jALAvVZpcQnyey6SOF
# DATA +3DKPEZx1rHxJbBGiMSW4UHbq+RmI2ZNO3tW6KDtSXDQIDfSX2ak15ygKw7wr4br7LYG9xsZ23ca2i83st/8wC7VcjUH8o2ut9da
# DATA bgIUlKcMIloUQLYa5wU8btisqTf/6fguTdr5kBPjRHQBggAT8+/MN8ESGNNW1JZQfss0nFHqMpNuSa0JXjBD0zl1YbPFTtgg2FcL
# DATA HORHPlBIo5R6u3zQj2W5Xy9sIRgWk2OIkSEApZFklUEinwpQuWKN9AkwP8lI0MV4EVVE78ECyY7Z4xGPPGpVD4WGckIdBfYMog3y
# DATA BoMUeacdoo4e5OhBjh50g/Sg3caUHaHmF9u8t2y8X8V2f1rT3bGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMc
# DATA O8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO+i5YQdF9VF9FFyRHeR3G4NW/QViB62uO+/EDzoySeZdhEXWzLAVDUf1TayZ
# DATA e28M4hT2v4B9AkmIAvt0WKSB5Q18XxGGCre3680Lbrc4PxS2R/d49FvV79HfOv3ba32frk/8Xp2utb3Ab9K1drXTqwbNYNzsfRAA
# DATA WNTpjjvNqd9oVZutcXtdTJrBpogrgNGdo0IFagY+IkNvmFZ9r34siJ4t2RiN+r32ekRSfaV6UpxbQX3cbtY/QKqbvdZxsz5t1pvV
# DATA Zp0+lRFEvbDTb68LOrg8DUjqvKYBSfOxaECUjEGnUaQB+Z1Gt9mzaUBBvdltDQs0oKDbarTDnAbUHw2bw6GhAbUanX43ymlAo9Fg
# DATA 1B3cNA1IGSXrHR86rSVbS41E2LhW3W6FeHQzhp383jL4x0yU1k2KtBsNc91Ks9Zk/k/A/J/V9ah2MVLauLG6abFdOCGU42FaPcLU
# DATA GDyL+jA6qlhr7/ZnL+jNH1W+1ai3Ou0+u/32K5tD6l0yKB3lbB4NLksl0jYvvIcrJpW1Ird5cVwthYtPuJrRD9PoYBimDzezh/Ic
# DATA rthR32xzlMxeqUNsOzmSkCMJOZKQIwk5kpAjCTmSkCMJOZKQIwk5kpAjCb2yJCFF+vnEOtaVn+cunuMqY3iEGySnvCmPNF0IOwLQ
# DATA jEDnGUxrDPN5K5myAPrKIW8+3oalJFGrCnFQJZmp42takLZ4UEzaqEzk9EkLd8bZnXEuHLVxR53dUecrHnXeKD54M0eg341Z64LP
# DATA 0rILsnx6Vh+Fft7kNm5Dj1sNLqg6VF+VZDhSuTeYXiTRbJ41HVZ+xYg0d9dqc7dskWbfrxdlmltbpK558IOki+q9+MIbYssaFWW5
# DATA Jxe41g+9kXBnaktIt3m552Pq+xReiOvJG3cSJRK45ok2ZxeNLd4db5FGD1kr8sLHWvwi2wyYwqBh+eTis3ckNTsIVb+j6yeqrIcq
# DATA ++KqVH8QhdkSotE4WDsI01yg+sFCJPmoJ0mShdwgx5oh6xMeQewZ/qgTGrNq3g95cJtEx1Rp0AGiU52qsLkZKzhNkhrhoTQhc7Lm
# DATA fcwLAGIayQOst6iE/Wg4OUVBU0HEi4J8NWBahWP7co7US5c4440j1yEO2EPD0Yzn0A8ki43qLBd+RrOzZTaPRP+QFbPD2XKEgTjF
# DATA XEoCBBdpGI9GuLLss556jHGaAmPszjpbT4kQUBIWOwtcvyznfJ28tTNfLfPV2auvhL16WW3rZyzZw+va+QLsdm3r+zQasdHIBiTb
# DATA sVkuRcEchWyLxvVti/28EHoXNyFrvVqvr13aeq2m01XlrfNFf22OiUWhbJ8IZFGuc7moNZs/p2TSCFCTl4LodTXvTdENolmSiNVE
# DATA 4QwmyqcQERK5lwyDG2NGheDI1Q1mFFldsRZ+JhsuIZuHjLqH9AZNDLlcxfmBFmIxqk7GHf5qKZ4UcsYZQ84YKvWpzpvnvHnFvnOj
# DATA FfWMBQ2ZBwxwcTKZiM5+Gdit2kmY5RJ+Ne9d4XSzlbROnq+g5TdPk0E0BI1bpOiS9PNlJL6cp+Fz348N1NnQeBc0gmom4DReCGpa
# DATA RlKPtVw4Bktu5Efh8ohGzY9pGNa0wAoHIGaJLPcovAM6jHA0glOMXSW5y9OM0+/NMN4vhF+7VLSIaNqPhhBBG0b9lEZkoSLzEMoi
# DATA gNihtBVlLaN/Ls8oOOCQqgL8oKwpqEyDTFsXUI6DvyYVZ6kSnyYbYDiJ+mFa896H/YRoUiWlzA0VCGwYooMBEqE/EeG1MQvjrRMy
# DATA 5I+ZpVooLtkM1OvPqeDjEXTephHW/uLBVhj5mFWtufLMFvDgsBfZJPlTQDmS0cg7oiFLJ1H2SXqTJWXqIIRiI9dj4NXDk/BUHFM6
# DATA nqoMM+3W4ezjcYCCUTGnfMlEgRv+JVbhPlSyhpDCTPlkgaq4pjoXwBoL1B/mjXh9ikC00eusUs0jjYwtkAlnPnguVA3BKdOyyIxJ
# DATA KPExyCQs/xRP6OeK9kNxAnLYziBM01NWbrxPeRay304FJIR5gcdpjs9xyJJ8eSZ9GMWcKvETK/VLuOSOkmRoudvlrQk1NBoNR9LW
# DATA ikV4Ndg32vIpqz5SH/PdS8O+Ebfrhn2LXR5LA1f6hfEM4PhoeAPQ7zfBvFdyoWrryA0wvj8tqZDeyJsY7v0+mob0MTSuybacTIg5
# DATA 1/s2PgX0qaEkYoVoHsap9xDe4nA1dTdJFH85pjoWXCYJ0+ERfOs2Xua/KIzMNwx1AR3mS+/sq7N/Pv/5+W9WeTL/je77w9nvBPnC
# DATA dzH5BVSYb87+RB+/YJbMVxXP8GW+Ovvj2RfA1XyFn6r6qa88+vqFDopuoxf+8vxXCi5D8Tj/e48ZM78DmwYUGgeVeQEwjTPN7Frx
# DATA xc2jBAhoNXIvRGD6LT1fE7/HEW/bxiCnoGGs3cvywjm5ywx8FD09FC5nw62Umft8S/5mx5gpzOZMz3DblJnVcrk5xgwn0Nz1PQiJ
# DATA U15PRuX7htB+NkAv7PddpOHpdaJlqA1kZGOnImBOMw1YYzwTQ0E4uMz2orp2qozphIYxmfF8Yk9MHTJf8RRE7uNHHtcL72PeHiBu
# DATA 2yPsj1y3qVzYh9Bo10rfKLNZtGBNc+z9oDE8W2HIbKt5m+2UlTb0rPgx26Lv6DFuSH+qIV3jZK40kr8aPtnbG8VvYBDfaQzfcQi/
# DATA 6RFc6mI52fm2yWfYYm4CKVNOaE6WMZoTecwpN6NQIWbgfmO5AXi6ZlSkmazWIhmGnyHDKtATx3HKuBgUlsbKUMrDDBdxZNwQhbEa
# DATA KgPrJSAyp7C22LcrIR7JNjNME+hjfyIet6M04vMAku16q5vyrdPoDykE/n4hj+QQ4z9nSWrZDEXMSJQ6WIyDxThYzA3CYi4YM3ZD
# DATA wl9o2d6qeX4lTvVTGeeOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCO
# DATA D+P4MI4P4/gwzw0fpt1p9pv1K/JhRqNRMBy9QHyY8przTnQYO1sadc9vdcaNTuM46DW/T9+LOdLvdDrN4Wp2tgLP79YpQzvHQbP9
# DATA ffpefI7qZrevuCxcllJWUnCnwmEJCroSzV6xjJvNUkT6Ua9TDjAIGlcNcFjvBZ32SoDd4Hpj2Gj61xvDplSd64uhXShUlteQh1ah
# DATA XDLADaVsFcq1xNAulGuJoV0o1xJDu1AaEvj1tZRLBnhxS7mWGNqFci0xtAvlWmJYKJRW83pbyiUDvLilXEsMC4VyHTEsFMp1xLAV
# DATA WG25Vyxlv1EKUV1IVe6XB/921CihuNq9ZthcC0tbBx1rtRoWdEzCTw0SzDJSdKgr/LSg9XQBtLo9K4BW7/IBFJLQaz9lEnYL4DI8
# DATA M7HRNM9MzD2LZxY2281GVOSZjfh/Ns+MvvaiUYFnFnWHYX+Y88w6/Xa71TY8s2F74IfdnGfWHTTD4MZ5ZsrroTY0mJmQOOPJlmQH
# DATA heW90IvUZn7W5ZXKNYv+xZDLHLPvRWTExmFFYlLai7ImONsRyYs8xdDVuu/F0TDTl/W75PTtNDk+inZbKmrtsjhthVpedbZ9JrqO
# DATA FN3OgUzkV1YP/Ya1SKzu9YOiF0ZXV95jOQ6HyQkvxGDFre7pOmflbY8dFjwrNrO5Dfvp9CRW5XZ9MwPNztMLPBpWbpXqJE+WAwdC
# DATA cyA0B0JzIDQHQnMgNAdCcyA0B0JzIDQHQnMgtFcbhPZY1e6YCu6uQpnhMyW6wklSF3F0Dxkht4vq5l3q2KjO7KFqxXfrh/Eb/MRh
# DATA /Prr+49xkW87jEd7J/GMrCuyw07ni+S7MOI/BhRj+iMOZ/+xbkHzuwxaYxDIXjPoNXvtTtBr3+Eo7X+H/6go9O/CBvwhzd4bgXS8
# DATA /v7hMHks7yi/Yq+/f/iEZTP3+j+u/+TeXXrX/qFIvuHCtzno1/3DJxEZ60oLzoqL8N84wD0Vj326W6mPzpc06qlu74lED5Xjrvr5
# DATA p0k82+PeinIQfDg0htfVj7JAu7cXVvpUHOHr/QpZj7klr1I7ie9utGYnMQpmEtsV8q40Dyo3epOkjWaOeC3b+DIjwAFytPs5thLM
# DATA hnuTeP9Q8qj4O69K08RddcX3/Pp+8QYMwSo+b+Hempyepsr2RCPrzNFPp6zilFVWlVXMYWCnruLUVS6prrJRFPsGVFc+hhyXVgCZ
# DATA JKz3wZpdRnjl2Qp53Qadjk0BuiqeIC8ZcWIuwNKph/IeSX0vqMmuEOl8C0jXtnF0/hYYHZsvqPr4gPkHiqIEo1P35DA6/dAKI64t
# DATA QT0SE2kzS47HpHfgXb/oTl/UgMkCvehGVtj95CSaUCd6wb1BXd07IxO4dO/u6Dqu3mjlXKIvLLXubzSjQcajjKyHaGik9oy8DhlZ
# DATA RhZHzPey1A6T5HaT7WERGy9LlilYviPBqUB/W6xGaDjkfDrxWpCROFMyPpTEU08dujdiMfTOFbWYceOerf9DaWpQwUx0obBFZuem
# DATA tVFXlcBkJ9rcy6AYko8lzuh0Rueq0ZlbF87qdFZndqE9+cy0/h4waogjyS5uIEdR/Y3RaYBk03iQJpYE3pItVKV/F1Lrmg1At1jV
# DATA vjODYt6i1GCoISUsJTdIptMoHcR6DGTLNY2w0oKNCztr/3HK5vceiLeqfwqfWYRdJhhGDUBJ2L80mGIvxRr9LXXebdVEVe5Z1ET+
# DATA pIxTZXPoH3MDyFzhg89Ap0UcjoqfLDeI4KCO/Frb0/h8wQlSn4uWp3WH6Sjtp1YMOzhN0RbAmpL74m12oDbO32YDbtNdgwTEDWou
# DATA x3zzW/nXzc9wJcLdH+HDFutSBmZt4YkL1TZJMEhsMe8KJYw9H9Kg1dHOHOlAnZJhd7DHWlZ3VF7aeVHCAfFuGNPOxRnMtSld8u3B
# DATA v/z8/26bVJSjrXJWmWJKqpIqSLo4FWOM7DsemcDk0ZYkD0I07avC7hryfNG7PxxCGo+eFhbQAI2Naj9PFJmfDPYKHmTzT0ZHJqJo
# DATA YjJsU3pLzXsznOVUwNlQJqXy07sgwuAljToNsoYSpI+dXClfS7XnCtnb3Jy9hboouQx7WWx4SsginOh8vs88GRok5hXJNT2x5lwL
# DATA sQlgEU8jG8o2nyx59kzzy6VY9ExAUh597348RV6NyFrLxoBVsemNS36Ar/MkYxO95r0D+CJeM4yzwTJDAXFIsih5Hbls2ttl83dz
# DATA 3qqWq3MVPT51vQt80Hn6Nvb2hF7j//xTA6ykIeUJFg9m4JmfAB9EdWtJeUdlIVP8zPOpQHtwWsj6yyCiOUjN+4i6bJp635eKLdUX
# DATA BCjmJPF5RQ/ujUPvTfsOnCEUdwnPpNUmr5r3ffoacUWm8r+2inzlLN7eQxSy+VMaaGmSQUGkOo+NOTuihl8VPaecBQbtQKpfqExz
# DATA yUNZ8cmkL5C7UUnhpwkVehwTQnnwQ2iX4mRgxrqloQkknGkoVUVeRr9hCUXixpl+FIvkKXhkx3FCLUQ9HErP83x0Hu1LdR7/dhnz
# DATA yqcevHUhSAZT/aUxDhWbKyDbQNowkukQst3LJvGc8pMbB/ctAJ3x9KbP+qbaIwgFVYzqosTKXZN3FC2k6DgLsZCYJdMIF46WEXcc
# DATA eDqeyUSF+qXFtXQfNz/4vcXjEphIsanaplsUt8biJJEOWbIWvXEmCE0RSo7ilEa3E4Si6zHL2MZG4Zem62j6qWr5ZAuyqjPeSV0T
# DATA TitSb32sJncUNp6YJljI5bkDegrGTkj3Apu1nLlFc0WWjW1zxVyRzLpHDUwt8GohYRm/xVS0zFdqbmNueFIotYtYTy+DyyWfbTmX
# DATA i3O5rCEoOC/Ly+9l2ehAea6ICoWjAqsj5cRmLXiTeIEjzqyEwkhMUCzVaMIumPxBPk/CGfusEQzPs1b5Rfwk6+CHrEry0Zd7b1BH
# DATA Wm5v+uh74XhdV87yWefy5UI4ke6wjJNYOZIu7XeQoHbI205nAx0VpfKY+91sMXsujzVgDus5/sLpUSsx4+DeA7bJTRUBBDmcnZpV
# DATA q+8nJ8Ahn6q6812PLyzhnSKr6rveW3R/RJ0pjCEYIbkl/F1MwuIpV7hZdiKzhwU22nm8dMz6+7Eiumo2FWC0Idlm4ONCu4wMr37y
# DATA KFrhRRVry7sxAzPZAUnZsRwsKJFS7K/CkpPNuUyYx21TLv8zYyn/B5CT57/1QKQ8+/3Z12dfrBIuS3f+JQde4v6Kd/4LuvYV/feb
# DATA s6+981+f//LsSzyBe7/C7X8UBCbd/s3Z78//A+CVHn34Od32J7nVcSxfAJPNy9jvn6oDiKavR6J5cs49Qc2T3fJetpQJq2zIZ26t
# DATA PMgNGGMGDybsEZjJNGqECSs3OPjJsLQw5s3zWyiWb4oMmKAyHMKyaMJJo79tgGWpSG6OXgk74Njq7lXFYwq6/FR+QlVB88THqkqi
# DATA Cs7gEbtWoCXvlhiHGftrgP5RjnJlwTio5a4leO14y/uwS4/EVjHs6Ap3m0M42DQgyPRZYmi/HY9G8QAb8rFtWXbcRJoBrm+dRRQG
# DATA /ZyKu3+FaLlTHdxslhRb17PiWu6UCAe4dGP9U4z1Gm95+SH+FfHQ3NLwft2j+06D+6XH9lsb2qVaFrIhx1w+s3ZzE5DLQhoxJQ+L
# DATA CcO2UkkAgp3OFzIUzlN0PeDUjcN+zAt/i0yXGj1xdIQFlodUDTKZx1M9VsvcmG7LyGxG4ElMFRLLX0L4y6D4l+6KuEQ2GiYgpg0U
# DATA /wl19TjDhjUQhXbUsedtrytYSVWTqgVjQRaEOJYskYJQkIfIAKx8ZtV5lFbZqqMSWE65lz20zATciChXyWDbaDY4BqZjYDoG5o0w
# DATA MHceYHaayVzCHr490/4qlv01GfYOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCY
# DATA Do7p4JgOjungmA6O6eCYzw0cM2g3ImZuXRGO2Yt6LxAcs7DyvBMZ00K9+a2cstgoUsU6pQxvyO+S40VkWbPbrnfWZDiwm+1g3GxO
# DATA q82m53fHgjqzwGNlGlkOHmusQN/qVlxLSLWVuNbbm+La77e7rXAlrkFAce22ryuuPSuune7WuCqY3dq4Nvtd/rUY14Zf9wKqv9cT
# DATA 10b3WupAZ9Bth/5KXJv166wDzc611IFhJxy2V+trs3eddaDVvpY60Gl3+53+Slxb3aevA1ZwFFqz3Rm3G/Vjv/39bgmPSx3qoHU1
# DATA iB31pRpiJ92yBbFrtqnb6O4AsRuOWkWIXTNqDus5xK7Vabc6LQOxG3QHUX+QQ+wavVa3E9w4xA57qKqyuqFH16bFr7NodV22OfP7
# DATA L8elKztdG/lSa1ucrhwyn1PZzZfa3uZL1XPCPNDVVRnla9bTDEwU1JSr11qhw8GnhgUn+U+DfzdcuHhGdcrrChlOKkOzSKdTtWYd
# DATA Ze9qxDhZMVCLuGuLwLj2yv6CjbA5qwS22KarNcbx5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O8eUcX87x5QxfjtUbFUqOfZ6U6O/I
# DATA Vz68R1/v6F8FNMfG5mevvaOO/w3NSUgc1mOSGTPZBlE82ePQmawm+plZ7TP63+z+ArdJsOoHBWBT3xgOo8Md0oTb4xM8awK/Uw6F
# DATA g7EezXhEMLgzp4PoDtpvPmjvDti/xAfsL6t++NwcvM8dW9vVEFnkjU+zzmiEIssCAstj+r5NC/HZntN/wU6sXqS+kzsqb0IbsaRC
# DATA cM3CiGUdhwtUEe8rQA+LIVCuUhvKODAjLfTREt4Y3sHgHS0BBetHzAYLLdVv6B7QZB3jtPcuXU0gcq/VD0UmihENSl2B6m2iBZzl
# DATA RDlXdSXegOznM+U4h96XCoGnUeeiR3OZViiV6bLq4VYlpVKTg/fahl+w6vaDhEa6sTqtLptftfj2hyHkFo1MfxqdhCkO1CtB0ZNw
# DATA IkfzQ1VBvQkSwpwEdqDHYSrCFBL54nnoRcgiqT9YLpAkcwi6rFG+Gkedy4baMJOSYIoNdxDYhOHhyzAKjZR6mLFKgxLWChlPw6fV
# DATA 48WW6L0H6s0lIodexETMEtLQFQkCmBkVfpgqgEEyyRSP0dB0OJj0oXeCXojji9P2WyL5kbxmTSa+QifW7VCcjexs5LKNXKpVTpbK
# DATA yVJdxTreaI3fmFzV92JuA2wkhEroSSvYUI49tLSrblkT8TbgwOLcYQgOrMc0Qs5BpXI7Hlg/ZnoncyEn3DbrFyGCG3UxZHegBIvX
# DATA Cche42DiS+wSwssviLB+3kTYXMgj3FofYYmjirJfjnJ9c5zZNWZXXVStPX7xHfFM7V+YzUUKs/6exzlYG+fWVaOsHWZ0wwfrfW4X
# DATA xDgPwETaumTl9dpoW7FW1UdHulWI80Yg8pvLeDK0RjT0Fi8uF/kDGYZldA/nfPSGF7D1XMqAk7n34lMiSh1Kkj+mhyLwuO57o+iE
# DATA XdrsOF4Yjyp0sNYIyR+lLFRnxv9ZdKyZV0YC7IeqX9ddIYBrIbDo2D/LBnnN+3dkKQx53kM9o9XNktk/xM4gUV3TjExxZUtHyo2F
# DATA UiRvZtMDUzqaZggHLl5smrK9xEa4Pbo6I9wZ4SuO6hVry9nhzg7fZlY/P7KxarDTzYB9YGgLtgo8cDs0VplWeJwPdUqitJKrmPJQ
# DATA YwROodeJvVUYdRD4XCQ7MbwqJyLa3EiAKNkyFsyMHAbZpLl6ZXpy/lJu2JDA76NS6FkEjc5Dx0/ehZ88Yx8qnhBv6uY7xZ0sUwh8
# DATA 2kJO1m5Fy/kHiu3zT1DOc+OSGMlPNiMkdb4KRPJ+wXMPlzZVGUBp0wjFVAKmptER5Zjxz7IfVpBY9J8R5s5KfZZqZMY30m2zRUwT
# DATA ZlmB4LlyzXsrTNNTiLIms6J7PA2Z2chW6yI9VV5iFmXFHshUIgafeTLTfnI1ebAbab76o5tIvrpk9kDKKL8l+SZ/tYoiXeDNvtww
# DATA QzBOzUzkqViheVW+ZDG/s7mYdaNQxWyc/vmSjOy14B5DF/T76GJh5ITCZE3JYterHJmFrBctAFGK5qUXCTybJCeTU5GETlnZGJ0r
# DATA xiKz1ENlzhv40EGOTa/4VEW4PWm3VoiFXuaS5fjxFphx3l/pFivoESWRnEZgsdKQMxsqMXAuSU0Cy9vpMA5pFjhlA3UULU5pPF0i
# DATA j2PlvAp1S1a4MTOZ50UXGl1zPlpmlnBo8H2EGSn73NgDhgXCWIBrT902tyX01sr1yn3wg537YKqwC7pF6LqRN2P2dvbwdKX/1Wwb
# DATA KVZYNSI0zUbGOJrG2Zy1r733uccM2UswCdMjyEpDmXGWaU79SZJK/yptRTrXUQhEMtwC19Iu16fq+e9Wv79zt6rGLrKvIK+PpIZq
# DATA oBqGmmBtmqSse6O7TLSxKHYovC18Og7iOChKxbeOj2Zw9chEVFuYcKywNDiMznSesl499bpSzByP62h7OyTsheha375U16pl3WGY
# DATA DNPwBA2EdydM4pG1UK2ca/oOZT1EIbaFUuZA9l7sHduewYyGC0ubPIPlouaxy8+sZavtAYM0nCPP+Uio3k+hPWRPV65bU3ilEr1d
# DATA gPdTeWhffp9ijsAcRDTax4OsiMD88vznZ1+c/ensq/Nf0+dfgGcJbOWf6M8vwLE8/7m+uA6L+c3ZH+n/X559ff4PjLs8/zuGYv5J
# DATA kJgc9O/pyq+Zn/k1kzO981+d/z0Amue/YjomhX32x/N/pCB+RX9/S++kEHDTL+iHP9DPdM8/00u+Ovvz+W8cJvOFcJRiWxq6K9Ut
# DATA qprHQWcH4oviIaxP04MKfz/CZnd4UQdA1ilQy3HInqvQTBGMzzX04IUbjGveO4/mE5gv1JmisBBrZdDk6sBb+ZlvTWj8kpaI+DmC
# DATA pu1D1X3GbRM0Vwrl5hiaXCnNXdhayGvqygO4Qtykqh0n5vYH/NWDaNdyApGw6wRoxplEBd5D2dkY4cxvCH7QabRw9Mxdyu4GyJm8
# DATA Ssqr5fEUU12EZiqA6p4WER9RG6Ae87F+74MozJZq+ZZybAkoFNMVUHLUVxrfc8acIW8RTyLlsk7ZX04G0nA5WcVp7lYlN1s65bb2
# DATA rIiau6XDITWdXXATdoFmbV7FHHglllNvzRS4fktgJ0PgUnbA7ZkBUi9LuWDjNp+3NnUTHM5S8jnRcFMzu9BEpgzf1ArFeeYcw4kx
# DATA UTxO+yAN5xYvPRvlvxzAp9+GzBBfjsZXZg+jxQB+711xnPmIb1kMFLksH/6nYicMsS8PqlFQqKH4ehIin6wp2AO88E1xS4ZV5cdH
# DATA O88y3kfm8R4usUW0U5FGJSRX/FGK1skbJdhtFZplNIfedOhNh968EfTmTmPNTlOgyxjNtzkFuMoM4LomAA696dCbDr3p0JsOvenQ
# DATA mw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JvPDXqz0WoO28FV0ZvtUWfUfYHQ
# DATA m6XF553gmxR6TMOiNxCZsR7n5eBU6Ia9PGODpuhQ8S9Bu8gv7A1HUXc1l8EEDBpjP2h9Xu16Ld8LfM+v9/hPo1XtNj2yj6u9RrVV
# DATA 7fSqftD2gl61E3h+h740ioXR7nZbvUjeUYxz0AzyONP78ji3gzzKQha1Kkar0Y5WUZadnue3OuNud1L16xS9zuc9imy7UQ3oh3a3
# DATA 6vvdaqfaalX9Zq9UW/xoEPkl5mG/HY7CYB3zsLkuKU2J/UDFuGNBGJtWUop1fNgdDPpriIx+12sE3c+77WqTUtLoeXVKU9fzg/rn
# DATA VSqLRpNS6HsltGIYdZrttXFrdTt53ChgK5t7Vs2oF2mRfnPQbF+B1MhNT5MapRVbpEaKy6C3C6mxcAWkxiDqRkOL1Bi2h51hTmrs
# DATA DINhaJEa/dag27hxUiP2tle3mTQ04Fo+LrGNzUPakrGhhEjlyC/NiJvdb3v4l0wNj82NPAg93lpLjPIrm5M7ev0DK35r5xIcIgSF
# DATA bZ9/HXfzHESbpoeWAV5whapyvxxYUdxfORSylCctyhP6tyH/Flarmi2Djey0vr2W8CjGIqVZ5nz5cqm1gLUe4bgR1XhhZdD25Ppa
# DATA IJkS2MW3czilouFZbGky5DiQjgPpOJCOA+k4kI4D6TiQjgPpOJCOA+k4kI4D6TiQoxCN+65fFZ6ibDoG/JGsGY18fKDPu59Eyp/J
# DATA uMc9hYvEBTwhQaGqvouNfns+IxkHU2E/FgJRc1UrFLlycTAiIgvxZHWcXo7ae/M4GkT6NCLOyMF/2Ed5FDmQ+ckbdzrcnQ7f+XR4
# DATA +YiWOyjuDopv191+bg6QP4gfSROq0Pg0O8WSfyyHLG3wjTnyaImmoslM5FAnnn24euoZR0G551Vnp0cIRU5mZuEkuqR8tlG1FNcj
# DATA N3G6OZnCNWqf83bK2bsoZ/OOEq6K+LD5PvSXuO1H9HeLZjYNigvBH34kH18EvWyTB5cUiXxzs0ikyk0RiHwTpzhHONaNQSnXg8Rm
# DATA GY8sd6oqOA+O0/ngstKU5xQCnpN4JCeYkwVTIDIemuCCQjDeKKJ6NIFBRBOWRA4ec0o0EeVptDOvmiVv7Zgl72hNUBqTdYa8GU6g
# DATA K8BavRxdakx8wZy5liUclhX1RvAu09PIKV4g4XkdmHM0NOMPNUGy/mI5mY/AZteRMbodXDJffrQ5X6RFqZqyHLJlkteRWZjSnNSb
# DATA 0ZzWQz/DYFBIt2JBAjIDOfwHFg1XqWgmhDIIEmTMEaHPc/T3x6fauHmGdeTf7FhHPkqWrGHx0+VRnh9abXqu1aeT6QibRoBpoE5g
# DATA jukVGgTTjBTGaEimBg1mA8q4yThZ4sRbzfsEEwLWVmClBLHrjibhz4xQx1Oqz+Zd4SXz56Mt2rO6U5Ucovm1N9eXJIc+SpNj1AFK
# DATA M81ujiKDjuVNclRpwuUAKhz3Z95yhuTqHgYCwQxEBZZpAuV9SEXz4vIzbDcf79huuFIr5RYLWcuKDNNkCfXxJZQqJmI8pHxGFv5+
# DATA ULGGQ92zQGk5lq6UzTJbiDeU6kL9dTk/blfK9lVRaMjNbDcJd5PwnSfhbsb9ks+4N06mn2vJNt7HYna0CJWVd7Xce4MadLmE9f5L
# DATA JNdsq+vKVkprc6hcCCf8rSx/trIvUirMIMHOIXnZ6WygY6JOGt/7wcq2Sj3JX1WXsx7jL5yawvg+KZC9AJ9g1gsrjg2petIEXvsX
# DATA 8of46DQPN8+pbt2LJOe0o7CtZ7ZUSfUtGA5mA9UWQ+1f/uk/aTOCXzkORMpOLEhvEU0mPHVRoAlR9Poe7M/MOxIrK1wwLWIIFTaa
# DATA sYyX074urtBLx6eL8VRZs2yw8tzgKJafxfJjMTJMmyFqZml+ebznESJdShq5QrmVRrngnFED1CvQghnK0RUnYbqiqVssUIYaGcOR
# DATA iVWvoKyWFYyz2pzVtrPVtlLf3NqJWzu5gsW20Ti8SfFdBjSNlI4+i7kjr3khvqDB++wF4bcZAjjn59lrLStLJ2Irsm05LFwrrGnI
# DATA Uj9dfpf6Xz77zVe8vcH0ItC9ftR0Z+aCWWGQAyJlZLxfBN3byPh6zd+8/qI2FNiRlUu7xNY8bKKbXzHx7V1ndNXGC/r9A63/u0gW
# DATA hSqx9+2Lom0CMdHOr1yQzXUr3o2t0Vbmq1kwk12pvMolVT7iLR6mKWQWIgo17N4bciZYxVltT7adavkl6X9iQVXNaexWRuwdCeIp
# DATA 4U9iWzFKK+8CbFXqH2ZmfwkanzFuPxBnqlFqZuTwyTieRHk/EUOtdoG9OilL3pqVDmrNUS7ezPLAaoUTJq5sXJGtb2TqlqqA3mnl
# DATA DRWqz/QGWjsYXarV91CqllO6H9uD83BYT3oQzqAdPKcExDinGKZzXuhlzzFQ5HBXnowjMeDzjgspg9A092u8sEVGR81TMDuk0AhN
# DATA Z8s5dT1KP7goLn2H8/1VsZ4tCBfP0XkOYXO4/okZXF+e/1J4VyBnfXP2zwrNBTgXWFxfrBK4/hvd9hUAXYLWOvufVjj0iQFbf6R7
# DATA NGTrz+e/OftfhtJ19gXd+BW/6/fn/4EJXTjp4J397uzLs/9JlSacOODWC2H/s3Fvbd0AKjBNgHedop/g+mbsGCa1ZpAnpy6J1fuo
# DATA Z5yJ6vcJ64bL0oWW3a4obugRGvs47KOfktm6qGFznYHYeT/CDGEbbOtTustEyKG2CqZ/3jPcNm2rVCo3x9oS2rfhP/GWbOut1p0/
# DATA zai49Y3FCnadiK1QwFYarqAWCCUxDq91QXFdO1rro5CMTvxMsW7VK/V6nUcNygDqomreRzSAGKuHCRY86RqHc6wF653/i7B/iEgK
# DATA jjozEAoUV/SIBgKcLSgztC6sbpvNlGLjeVbwrAsT4LhZbni/7uFdM7MuP6q/Gs68WxzRr3tA32k833k4v5XRXGpjIem2j+55akM3
# DATA wcgqJJwRP5littvJpEl3mKlFsyEWzfqwzEPsJK5QQmMgfajRxJSESQyW1GyoXzsK4wn8lYMQrCJmCxWThdE2NBk9pQFOLzDHs2yO
# DATA JMFFSi1kV1pWHjJrBmTyPoo/U5p4K/qY6hzcK3SRz5TzaXP2b8ywwsdz2CUTouahOGCTISOzxCzIzFlxStGDUzLeHsFTFg9DdZI9
# DATA EsMwyrAPMc7GWMcM4dUYCHcF6YpH2IA4GEfT0OOd70zhmvNY5FBaDqXlUFo3iNK6cAzaaaqzo/l8e7OAq0wCrmEO4NBZDp3l0FkO
# DATA neXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOnfXcoLOCZrPeujI6qznq
# DATA jDovEDqrsOq8EziLM5bj0uOMEzRT3S/IUbT9bjHDG73e5hyvN3rNVZBTL2AklQrKgkt16t1er78OLtWQQAZxyhJU6mVtiy3V4Hjy
# DATA gblukSY17DU67XXPt1o7Pd/r99r9dc93m7s83436ndAvZ8I0aDa8IGhXqWK3ely9g2nDb1X9wPf4WlWuVX2/UfWbnWqn4/ld3w6a
# DATA N4yW8FzdYXfYW5eDjAsr1fxOz2s2fKrweLVXH/fqpeBM3q0E17sCAoubkEZgSWu0EFiNdrvfCa6CwKpHvSi0EFgBBdTJEVjBsD5s
# DATA 5gisoNv2272bR2DRTKhKv+80aQ8CGiuLfqvCSCMjng7R4wNyhvukbThlfOoE6wBS7VpZF4i3nDwuuUysMWDl7rBk9htTvKtM8fwB
# DATA PWqX54Hr5nzaS9hlL6GsDsJPuGaxrV1MRHEhQOaInj3xUYZc/oQZBtes2JUxXGs9PrqiFj0Mm6BdxnmsogO/sTX94u8X5FPxRW0k
# DATA h/2Kha0nm5834/QFr9kwhduM9TIVfCcc17bKu3laX6rM6+rkcnLh5JKj4DhfjvPlOF+O8+U4X47z5ThfjvPlOF+O8+U4X47z9Ypx
# DATA vlAX1An5aHhoU78WWDLljEDq7kpdT5bpIEIF4Vp1GI/YyFQN816rDoNnMQas4J00TRDHt5XlheZFJg/10emR9MnmtXdLxrQ1J2AT
# DATA toLJRUXoX9jWyOWwL8wxEwh9p67is9fYrhHz3Hs3P/pPdvRptqYv2D98wjb64zw22Go5imeUHYpqxjKiSvfh2Ar+LXQ+1FzhUq3g
# DATA HOM0lDNUXOp4ax97lGl+yS+y4qcEdamrwUmoDxNjn3onOLOorE/6jSNI1ZpzH6d2qvpH+uW72+wOLkMqnzxdd/OU7T8uREbEqEwc
# DATA tEijehNOAyIeYvUfPjHG/GevmcBriBu91Vx4nfoqUNjoGrX2/BjkHblR5wafPSqnVyXXVLat7YXTua7wdguGJnN4PQXE9rLk2Z7Y
# DATA 0INFOqEp39/+rXzFZkD6uv/Xfy3f6VHK089ee4cRD6/tP95geSujm7rCbPGALfY9KVQnce/UFK6kpuBUFF5uFYXLqts/U3UF44CV
# DATA FIlYn6XkvghR3e59qGW4OaV8kHUJact4c0Le1mf3c+UBiSUe2vbgA263vM0Li0IbnypkhxgLVtvLn7qDmGodQj4au1Hg3pCYlBQC
# DATA tert4vbPndjEC3C4mv97zeSEoijGdXMTyloja6kJl1XJ+jSNlekWz5jVSLYbjBmjkmV0QFi5LIMFfAIhs+lSNBxO2U9dMQL6UhlV
# DATA 5eGKglEyE0V7S9MDGgchW/TJaMFwpTRiNzoTuBRwiw19jxcGWW98Fj1iH69S1riQY/RynJM3ITjjzhl3Oxl3JaUcp5nlNLMuYdVt
# DATA NB1vSkvrPRFsooqt5vLKicDVPCf73LZi422I3CvPgs5cnfQ39E4MrTiub4NqunjKcJmdZQWBdcrIyYQ92gxAwFoxj25/DRfTIfo0
# DATA +XSgLiiLWr5V5A+7xdVtP/YrQaXxExoUdYw2SMorpxq96z3+xFW2iCA2t5i+NX9ohQAcMLLhJPF4K8kW8HBTDG9wD0t3roCCN4rJ
# DATA Gx9WXnVeXB15THlEXkrZSOskzpZG4GwuraaiJMz+TXgcPpAuVqmZgbCi3aBoJiofWO/tZFbUQhPVrBCQFtslp/SxaMCE6Jkgkian
# DATA yhFqmjsUrkSAi54+wekuHjpZc8py/9U8U1wYEclGXg4WS0VhmsRTXOSNRhCsgkgc0y6g3ZXpqJQqQj4Vsc3kfGohpVV0nWJuqVf4
# DATA jetQzflMzblYdv7lsFDzYcaZqM5E3clEtW0RZ6A6A3Wr4fmsxV4/LDSSGQa6RTzNoUwPZJmUBVArFgVQUue9o2UQIbCI4zucXfQ7
# DATA msow4bEaupysFhoeUbyw5Wx2avQgd1Rw5eia2AgJimoBBB3FIKDGSu0+Yn1LdB5rvHXqxPEaS1X2KKCC8SdFB1KWjP4xN67MFZae
# DATA AHI+4nBU7GTPjemWNrOKzMYHhv7I56Jdad1hukT7qRWTETsHMDqiY5T74m0WJlqk9iVvvsvSsRWMo/m6JeQoi4847W/zpy22a5EN
# DATA LjsJbINF0cw3mY2FMsbuammsVwCw69y4JID98ZPNBHbJWCGwYxIXaUa6ctqfahL7J9gySilPl5ls9+IaOGPtVCWkizkQyJx6BTrG
# DATA JowQGyi8/pIMXaWYGg9q3tsxC6wuWWjXm8YZzx5lrwu2KzFFlDeByDVurbwyLCQGIIjodanisz012r5Ugy6Zwf/yD3/cnMOF2igZ
# DATA zZKuaSTCv/CrxoN4YZD3/EtOX2LtWzKqRUs1metT9wuqbSnr+OLw6iIW+/z+iA+F09xg2o+PluA+KtdvRXd3gooS+mNIxj5L+MZD
# DATA /k0m7NeRo1esq9Nst7r6YTiVqgAp6zzrpLZgigMFW9nnK6q20KmeRAsgsWR3k3naY4wHei8GfZwCLSu0rhmUAdEgyPqj6FDvSUWh
# DATA NiiYBvLsq9+/vVTlE9YZx55S8fkyWkY6/97HDA6TNppA50rMJ2HMzhy+oI6bRwBAvy0NktckpOJkeUXlgJH1Ixwt4PykDJzBhcQB
# DATA LeQpYHojUBRpqEShXUvVM137JTPyvS11Tw0SkoflFUpvkYbHNG6eUBp0Zn6sjhKMlUB2KNUyJRsmGmbKKKBebrZgcBzCgl0i8xNq
# DATA yDPTM6hedUq9RsZzyRgSj9ayag6XW8RKzj2i+a9W4Ybt90zz9ZNd8/UTJvBZy1U435i3brUclkZH2A8uB0QoIZkaMjDa5Or1RvI8
# DATA Y19FbhlGoxHnsN0PhP2MxatphsbuHblHVWf0pmL1xehsfyq7WUsZWjQSZM+ibSSYK5I9ZNfq3YV6YsfOFrXrjzqiwTiBflYIfymV
# DATA pC6IV2LhzcboUUlENkHvP599c/53Z1+e/a+zP5//Fty7818AiUf//ebsd+e/ETTe78++OP/52Vf4e/bns6/Of7tK1LPDYVbeL5jG
# DATA h2e/Of81njr7mi4yb0/Qe/T3Tx7d8uX5P9Bzfzn/JXB6iEE/jU6qBr339fmv6O9v8TMT9/7k0HovgrdGaprNm5cp58MYrXQm24JB
# DATA bPih8c2I8j3MMbIYhlD6YUtB1jfw+0O9nSSNBvFc2VzZEv0Rt/ZpwmL9W0l6b0m8rAbkYHq2lwa5c9scvdUyuTmUnlSdfCXxY6lK
# DATA InlSvhk9kbXmGJ3cCC2bd1TP1aELygqZMOJt02i2dDy9Hcrs2pF6YtZzX85dD7zM4jfrkwGhezex57kb+yTvlqi6JicK6qMJ56yz
# DATA JuhfPnSAQounU5zRAUyICtvAiC9V/7ZggMuN6lkh9i5OhGPsuXH+Kcd5jdS70vD+iizA3MrQfgMj+04D+2XG9dsZ1qVKlnPAQus9
# DATA y6ZzEyS9clL1ooi4VEOWmyyNiJk9JCL+K2NiRaBYsjgra6yiZHEcLZI5PxNlfKA9IXNpMU6G2S6YvI+Rh7KMVY4RZS88BLxxl5I/
# DATA jbHBJCGrDHu2ZKDPqwu9M8yWKcBgIQuMUiazP7+i3fZphPbDKTrlkhEdHCEBwrHCpDpdGbJwIrivAZzVmmfmaHiOhudoeDdIw9tl
# DATA 9NhprrKrsXurdvtVzPbrsNodFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXP
# DATA UfEcFc9R8RwVz1HxnhsqXqsd9Budq1LxRqNeNHyBqHjlleedwHgF6lujZ1HjGvWGob75nU6RGzcadHsqbyiCMY2sJohGHkSzWc/L
# DATA JhDanhyeCnqF8DrNYNAYrBRU0PK9IAjGQad+7Debn1fbXs+v+o2W1wvoT73axZdqL1hTcqtovlZAobXq42b7807H6/jVJtUDv3kB
# DATA dc4EtoKJCzprM6Brkfso8lblbLTyDGgU3vut5iBoN+orUW60657f8j+vUlqbVFuqHX/aalLcP68GPX3lygnwgyuA7rhVaNCdNDAL
# DATA dNdpNhrN5g6gu+GoXQTdhcPeoJmD7jrtVq/dMqC7YWdQ71ugu47f8JudWwDdoUlVt9sbHg8v1q1lPtz3IuoF4rAiAZcW81ZQcQ1e
# DATA MMuXy4pBK7tlxUmlc2jFEVny99thrfPAX2pQ9dj3VmfDST2jlsDWJt24VVcjaczyIkJOhS3ouvVbBcpEu1XM2tqcMQOfXv2qb6PB
# DATA 7VALbsoUcWg3h3ZzaDeHdnNoN4d2c2g3h3ZzaDeHdnNoN4d2e8XQbjbMTZLNB7buCkhtiFNur+1/R77xkiNjuRTyLFmEE7kfLer1
# DATA D8LFuMYzyT2+uP865QCOo9J7lBNtDo2Z5Zxv3yu84458ox8z7kUWybvYjrfn26F8KofJrEDK7ywFw8+uHDnTBDGZApojHe4QtTtE
# DATA ve4QdemYjztO7Y5TX/Y49Rbh25s6Zi2tgO1g6LXLKqs5Zv0MhTxug7owVMezVc3AV2/vaF9J2upmN2MHRi4Ar57K+yb1PWcWFFkM
# DATA 05gF6FoK28C+f1l0whYLXouq+ZuFb2U8hRSzGdZQDDhULfl/QXT18ya+5oKJsN9eF+GuFeFg9/jyoApKG8eDo0lXLoikeijX7VXf
# DATA CxyIlRj6Vgy7dgSL0dvIe3hLtajIiAa9uLiHt9jK42GMAV6YnOgDye+NoLKJPoSP4Wc80KHtZWSWzCvs06RWOoHXf3LqQUkTlSwG
# DATA L0+MIvHWC51Lah2fG6dmqEIcUhAUIMycsQ5wkMDoUSHp4+DMn+CaHGULrLvzlIolmKZsEVsiADgNzgqMvIw6xEkyT9ZuDm0xAJhs
# DATA 6P2yZBrpjuh9mr0cY4Y0ZgAGt+8BdgerBCHaeV9zMaDh5TlY7CCxzpLdbsk6u/Ult1svC4V95vJAvGBuLQSvGn2TgiQgU38yFt1W
# DATA /IM+HyOFKbKVofrMVYVeEAWOm8CmriggXTc5dY2a1Hp46m5KiKX6h6y2aQosIv1mirSqYZ1V23MFad7ToydCy0zgVJqfyrZYhHnW
# DATA 8LQg6RJ62CixnCr7DBWMPmSRMpQQmNSkooGi0Mnv8g3GKClLcHOcP2axV4lyRFmsY/yemajFPAekqIqe0SJOK6zMzrHRquwFC00r
# DATA 3tv4ADZIERRZATiCsSXaH2FhbnusHwC6omLN25SioY74O1riakizW8SGksC5V+EpX8U7xWZZUXVCj7FIjiKoWNU8y6hOWFl06jGo
# DATA QFFfNkVXv3A1xq+QgI3dJzlL01ma6yzNwjjlPKbOY3qRgfrshSklBplSVkyTZMoqddwgcnnKyUSaylqRxJqq5xVxVlRkMILuHJoR
# DATA 1qeZCsaeFU9W71S74mXEy1HA3mUrQak7SptUy40cJnq+OWM34QIOJ9jAIALZDgq2CxRMLC7btNp0p/FzM91Ff9l8v1bp5FxVnzff
# DATA rWU8i+bH848Ry/PvkhwX/8Bvb0a56MIQlMsPZhF1JnN2LVZxZFFbhljf8Fvekb2SETTrdEG5ET+NFIGMpiDYKjc5rZDdjr2/faoX
# DATA I3xdYLxEyNhDkmHNQ051ZNxDwNg6CbOxaKlqC50uTSbZdXBwbiX/PjlJOP+GNE7Ni7nXqBdzr9m1cu8BL9Qg2dzXqkyCYimAzguW
# DATA oxRpTLlL/MKTCPgibNb11CFcESq9htwqtMHLZ1hrc4ZZDVry7HvUp1Ls3k15KjuXCUyeb0Gp1jU6LSvfFjCleJmMDad4tlxgyIFo
# DATA 6aQ4seIRg2E9VPNodqUoeGYSdowdjZPnIO/al8i7t1AFUpGVyNcHC9lXqnaNoF7KvgpPpdlEPZKiyGieKkqpIPZJa8R+9GEanmAr
# DATA r14aYL3ZfGngafLM7sMvmWUfbM6vfDRQCL/kYaita51J7zKnQrgRQPcJvfCYbA5jppOF+5Aa3kShnYasOjxNhkzy88ZYB/Y+FqFg
# DATA Zlrhilk+MasyGQ30lOusyYsWfR3ZZg9ml65pweaMywdGyTjjGCgaaDoPH+Cq8rrMPL9LNWyo8yr0Gm3eM0QVFdsC2YVA0yXliBHb
# DATA jTHyXNcS72gZK74Xc2OV94bNRt5y/rwivF4Wh0SO8RrFC0jM2hyv//fsq/Nfnv357Eswtr7yzv5w9vuzr87+x9mXjN76chXY9V/o
# DATA p9+dfQPG1vm/xy2eILnO/nL2R/rp6/NfnP+m8v+z93ZNbhxnvudc61OUPeHobhMAUQAKL6SaWoqiXmYkmYekrT1raRUFoNAoEUBB
# DATA KKCbbVkRsjVzZibGcRyxOxEbMXF2JzbOxd7shcYeHcuypbnYL9D9FeaT7PN/nsysLLw1+pVNMmWTBApVWfmeTz6Z+f8hHAqTwvqO
# DATA fvujd/x3+KlId3xDv/+a3/TN0Xf05q+Pv2A8GJBdigD2a/r6RwqQfnLMrufBpZJB/dBlDm0ekPQhaQwfKDVJjQuczDpTVr+XDoUy
# DATA LJoKfHEf0794KC5IabdwofZw+hwcACiU8FPgMPJGVN7u2VEa+Uk4WIvxuo+V8W54aGLqOF62r0V1EFcN8lpSKpdH8lK1MFsyeqSq
# DATA 5SCmeE4O5++X2qhvfidXSS8S5gWXoYqJaOHLzvxIx8sBvTYrugtnej2KMtBBxoKYAJKquyxD5eCS81L0NtgLJDLCDFUwp4jh+TnE
# DATA 15L3dtzVs2Pq3WR6Lc4pldIFstfJlXG1PbPYyp4V2uvkVDi0lzMHLt4c0LSvs1kBL8Vqy1VZAJdhAGw0/p9y+L+a0V8q5kIuWNCv
# DATA a9aoLoMDtpB8QE2xNpQy5319ygpcA6F6xUmYT+c7U7U1grdAsEhIHE7Mm3RQnHJZcEJxKtfBRmSwx+zrhT8IG3BSuN6iSTgoKEuO
# DATA BrS4O0PxRV0uRhhrE6ohvIbczTBPHGFtCpgdIzAPKFBxecA5RW0crpl4VKQsZhC7R9bFNB5F2lHFy2cIHcvQMFsKYrPQi8UOMSAo
# DATA RwlzlDBHCbs8StiGQ85Gc6BNTeernQacZRZwEZMARwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOkMEcKc6Qw
# DATA RwpzpDBHCnOkMEcKc6QwRwpzpDBHCnOksGtDCqu1q13++UyksEYv6LWfI1LYwtLzRqgwO1/8wKv6zX5Qb83RpurUOzajZbSpalNy
# DATA iMtIyqDGipRCyvL9nFLPfNlVfLvw6rn8N+/MhR60/EsMvVXPAq+1coFLqrLA/WrdhoDlAm/1mu12bz7wetC68NBzoLeasNgEUubX
# DATA M9Bb0MwFEAVh2KwuNAt63PP95n4tGFSant84gUC2uk40zgAg48amAWTSbnMAsiBs1TcAkOWuAEAWdDu9cgYgq3eCqFk2ALJOr1Pp
# DATA RhaALKh1Wq1LB5DpBroWPlXyA00hy91vRke9QBBsQhvLB6F5Y1k/rnNqwZFpPdrGosySZzZdFijVlQVSsR0PldKSNWGfDaLcm3Me
# DATA BbEM8BzPX4w3yQ/IToBJtcQjWTEeScmU+WWWJQt9wcILKrf1XIt6bz+zS+ai32R7bhkXrdVq5WloWGVeTSnLlVthrizWWDv5G+d8
# DATA D8Z96DBkDkPmMGQOQ+YwZA5D5jBkDkPmMGQOQ+YwZA5D9pJhyFAXKJTuICpEvEzU3S0X2OnOn8Zkdkfp7s8/KsChuh/tsgVbQEf7
# DATA AD/tokreNhWaT5fBOpps73wW97bloZ3PdNDUQmGChKNOVBqRhbpTVK+6bQd/m1Wd9cGNbYnezm10BR9uPc6OsXUFJ/a5NcfBPkL9
# DATA filFHPtY816kn56ipLKSB02MJ9uqt4I+saSfEjDq3tgdq9376Y9h2N2m9CHwV+m3nc/46d3xbT6TQXGiH3/A1ygeS1OTS7DJ+tsm
# DATA w29LrcOEnht9VsMoz99U+s6U9woJp0/+GOVn7zEOSeXPX04o+kzwoPyIE8k+seVvf776dUx660TxYHubklpEmndusmkLyJvKEooJ
# DATA JdnUC2pInPoSu3F3PssqjHVZ4m7fRxlnc/GyGqRiiVyVHFJjwc5nWYah6FCcMWVj/Koi57GkG9IZ37ihby6NZ2SafKZifkvuxCk7
# DATA uq/AEaGJ9Qc4dfcfX/yTOtMIbF58w9+hLoYisRB80d9ZEzaOR9phP8RxSV7+WAz986wufK7qCE8mdZtcrMrqgdu52n9b6tkuZrC6
# DATA 6lk3FCpBOd+iJrORSAkLoY+rA7cyuvDaOgM3a/PqqQnOkJ70FJev3V1YNT/Lgbl+Zl2TeAiV1aw9qEQhKjpJZg64JFp8BiUe0HzI
# DATA 9Km6BprHZKzYyUWagj2IRzRdXBYoVtLooWgukxwzxulMnFFnwulLvPj6EqclyVwH3QleWcn569fjZN7DIXgQOSC+qg9Oh3t41TQZ
# DATA JhOama1lylxH0Yrn5wj3ZZBmFjU2Lho1s0zE5IysGS+3RCRVmlfY7vhlLQ0smE0jJ0YvU7dAwFPqSSbyYQu9PyGrrCCuJ9GyR+SN
# DATA 5S2reckYs0jA9YT10J9Npiz1Fav3jmnkH4l+QqKkPoyI/Rqhj5OUR1+gI/q5huNMKGdCbWhCzfWvTrTLiXZZw+9K4+s6iHm9PovB
# DATA 1MrLVhkpr7dEF8puShh5xlGChnbQT3IjlCAE9ABW8u5CxAZFx5o6ocyFFXwsekLNMRzEPSjeQHQbzgeRkBpFUVdjxk7LTzERVcAH
# DATA JacNafXCEiUtB0/ZBJ4yTKToWO9efV4HRJmwG00k8OXz6rux20e42ff40+o7tbmj+EL8+XlAp9i5d0qV/CYMx9U6+VlZ5FgW7NXT
# DATA 4vg8K8pGNoxfk2S2188awycMe2cJD41Lmo3IeGQtqmzDNNrzfhKztlWHzUNPn6CH1Thjsbkxy/fC2KQ47EXTi6AMnCP/gtPl3xtR
# DATA +sRjZ7uFFoA2roI7mfSyZJy4wlPmGdqmw0E4eEJ5peUDOTzcNhsA082oRi8acRmweBtOQXjd2USL69IgdTFMi6wZnhbOUFmfb1mr
# DATA lnx7ncZ42ffHTJ1ZbGqfsq2ozkXRSiFDrB6NwLKQvGRpOllMSBW9K0qnJe+vGYgRdfqj+NNZZBQUqZLShA6shGkf045+yDUR+TpV
# DATA FfcCcjPrpk6blyfUQd3rSU5+QHWHVRC1VLPBkJpMojRyFWILVaFGDRKeLNzOE0hBzpmyKvdCll1UyL9BpCaZnO1KQ86Ievfyw/Cz
# DATA asH107Xg18MB2xFqqhDZLBoYB5wh6WyMCRglMJy0D9XcoCM6i7LTueTxSg1yl+XIJ4rtRrnWiyKIKGKqRRZFlI6jTsxEWFG/nByy
# DATA nqGZhI+ig4vIQXvsO20FLK/PwmwoVbAVVK6JuagpuDTtGnLXhs5ekXrMNKwTgspDGXVABjZMdeyg8PpkEaJ+IctYBZSFD6lSQwdy
# DATA H1vF1B6bawtVeYFcG1kQzq/h/Bob+jXyNc25NZxb44xrQitdIJemUa6qbI7+ClOcqrnxbjxzVsY67wYzGVdy7HmjNy9zYPe3Ormo
# DATA r5lJL+9qsEdOc0XPejmXsvOR2BlC35JeT0yDsCt2Qc4hwbta6Ge2kUyvs622p+wov4hu4SPe0I9XSKTU06Zn1N/NPL8qxzcxDEzI
# DATA uCfjhc/c4eIwfCp3lOWcXDTmo3mrfSe8SYZTYpXpxlFVT5uo6u8mqpUTo+o3N46qbPtBZPnTSXHTt2exM1dM/GrLoudb0ausiZ1a
# DATA FTT+LDkXwNM/8PZu8j7FIZnYciObH5PhnVdFWiHLQhwLsetgdilX58Y0uE/lOO5NCSKryMY3Y7UPc2mFA0dMIpoMdi1TO6fw/5/J
# DATA Nu3oCSpNzHsYJQ1IR6YMByEN74DtjOlRMtAwA1NUoGwWq4GUik6oJltCSTV7fy2kJYbkZFBkmCXv2KK3dMHDTIQmCi9KwevGv/hF
# DATA jCGF3SujWQpB/vSQbN9kmGZeVDtm/WgwPmHheK5Us8Vj26+aLQNL/sueLXr8AT5kJX6mwGQrlzTKaGpVH7FhucReDqvcYh3OJmQT
# DATA k0ln0w7/G8MLvwZtMM8gPP4N/l6kHf7z0VfMI/zT0fdHv/eO/+b4y6Pvjr49/i/05Pf0SXELmXEIYqEEziF7DET8ChjF4y/oht8d
# DATA /wM99C1u+/7o3ygc/eTvj74HLvEbxiBSkI55+DzMMEz1yiYWXOFBPEGO0jMF5a/kDkcjMVg4ydCdJcJkET2gUhQaAQwrQ/CgnlQb
# DATA PeM46tBsfB3c8KHexkADAKPVHNrQmkzoArtquOFCqVwe2lDVEX0bOBuauMO/LNyP7StWh/so6ak9LReONuQI5MCGccqV3WENNyu2
# DATA C8ca3n86HqCXCbUzZJh0Z4MQ5PVkypo9Je8D9P3cd2X7vHjxCxvj6Vmz/4niMBtyT5nKNii4UJJpqNeywpGgYxaAhidXwdVWy3zL
# DATA elY4w5PT4HCGbqQ/x0ivuYVnGeBfDk/hlQ3uFz+2bzS0n3Jkv5qBXarlXB5YzMJn1XIuA044l0qsAIAEpDh/ccdKrD7nOJ+gUFya
# DATA CioH2preRJ2ieHjztWwr1hLdsJJG7BWdz7cNiYTGy5rFLp0mHV5x5PFYo+KYH8e1pEtz7VFqoh/NJokXDhn/xkN+RGZD3ImxNJ6z
# DATA CXIWQPQUB4sReDeCN0rtqFZrhWQ9UHG+F4UpIsS2XWcKV4wYiezVEUqdrK2rom7PDqV+OVqhoxU6WuFl0Qo3HGo2mtpsahlfpY1/
# DATA FhP/Iix8xyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSsQscqdKxCxyp0rELHKnSs
# DATA wmvDKgz8Wi3onJFVGHV7ftR4jliFcwvPpyYVBr5X9cv7xVbrU79RrDa8RkB/96tB5dNay6t49YpXbey3Wrlc6vjtaqc3j7GjsOpL
# DATA MXa1BbKhnPQTgF8rD/ALqv4cwa/WzMpajq1lBL+oGYWdRXCixQdsBrngK9VWPvhWdWXoJpm50GvlYE3owZlCt0uk6Xu1WmO/1hpS
# DATA 11qstfZrrY1z2l+EETZ8L/Ab/XoQzIXSCTrtdmcpivL02EFpNxo7KE3Qwg7Wu0Gz0T0ROxj22r16DjvYpb+7FQs72K0HjcBgB9ud
# DATA Tq1ds7CDlaDWrF46dtBsU4Pw/95G8/U13D6xb70Fu0ib43NvMwOlmnq9FVF3E4cFid9SgGGgVuIqC7Q+LCwuvGDO7W4bjbpA8vNu
# DATA Mvc8H3aAV5c/dphsnW6cQ4E2nZApYuTmg7oTzhsqFjYwH1l7c4Ee0dWyV3mZt1cWU/JJq8D3yX+pP/aMez1xcC5bC/N5ssZsWZtk
# DATA ticccNABBx1w0AEHHXDQAQcdcNABBx1w0AEHHXDQAQdfMuCgzXeTZIsXQ0hpfFQc0d/5cbN8o1Iu0MxS/XTARbgjUzaN+bovh2T4
# DATA oBsa2Q3+FVy6zhABR97/9394rTK+daNoXPqQ/huBtkbh3tktv/bh1gespc7n6HihBoHQjxJEiac8FGEJyxy+QVy89iHuZTpe2E4R
# DATA 4o55Cp/4Xe/YR9kkdV6UTuFHjm55//Hr/xeRWUj7drVSviFXWdwTXQOC1CgzhxBzZ7tPOtvtznS/6Ge6T0sKuw5nvedcbOsxYe+i
# DATA aZgnSt57qPa2tstSONgzPR3+/ByNvAwK2Pxh9otmgC1KApyVAJb31+qz+u8ytUsqgrymFxldmzfgegy9bkI/pAd8RvsBnJCoWiwF
# DATA 1A/jScl7FE/Z/aQF36UCinD5bCzHk1Xh5o7vh5mU0RiijUmPzyJnojlzCjcL5fwkgqkcGrkd2ERXr3TzjE7BWi3IGUPOGJo3hhZ6
# DATA VCd640RvTjKjrocYzgOpr0y06CYGf/FJ0jaKOA+NdgM1w3hvpMhfSkNN4SMnNCx0IG7Rw82iJJGGwK/CParxOLwhn+U7RIcGbsiB
# DATA rd2yRDNlY/DXY6jOwD+WKdnYPBj2XYhqh8N9bYb7oqRAn0QlfcqtZjXsi92OIgvNH1ffy9tzuWd5zJ+eB3iXlRen5K48WsNP0rkq
# DATA xJV7aBVUumJbCXDl8UEiYk3JDIIxIeRYBLIyREvREomo4SF7oUSWScxDGtf24UX+BeRZJsO8epGoFJHtl2TjXQhBGKodoWjU99hQ
# DATA 1mdOpdGo2cFyYedFAWiz8CY2SZZAk2NaygFjAxaUOWPoAUsQ+nz8qzOX3MONS+6hHDAXK10X3buwRdARhswGoOLYU+rfKZO+ojGr
# DATA 4yiWUB4dhuJjSR9R+6YikEnqXc1nhMdQ7Yvi3nQQTRVYYKLiko6T6fmLLJeyqyuzrDc5ZZn9ZB2tTPVLUmY/gQAR8rGdUIRsQBRL
# DATA E+l1FC1otieMLMpd6sRxMemRNWJ4Wr3oQDSn9OA2FUl43CmLO1zSB0x/Y+aKaXRc+u1Zenj+0sqn6Tkorvc3Lq73Q4DbeTGD+vqM
# DATA R5X2RUvfNAbq9fbgD38SHYq13w6hoOX1k6E0LEwORhwaa9SNPCqoCWhhQOWAV8UO+F78VPBxDE3ICnNe+O38hZZP2ZUVWjYKn7LM
# DATA Hq8uMz2eq15RlANxLSsv8UdgHz6GAWpCqbACB+KIYXnkjhon2Bvn3eXy7TG+izohiJBh3BPLE8emvPGMD8+xeMIIaJcL6PeyuF//
# DATA EqlsWiLvR0q5DsPHVP2kCJdyPijSA4w0J7E2RKgv8fh4F1rAoQgSChhQtRru33hmjQBgdvNQFqfaSEHpiv7dBbSZxYScqZiuljB3
# DATA LozJy+Bns4JwjjbnaJt3tNlVyvnYnI/tjIuNK31ylyQ4LVNymelhBETlho1pXGzPEGpwSeS5nCdL7z2Bvc+brLH81OR9MzwTVr+f
# DATA ADrLQjHdlXUpo8adhDqrb8hhO9DeMgPu4nmB2rW33RmeCLiTADLAnfpuAe6WYuN8uazBceWNIXeymwfuQnwQxphQkKFSzHk150BU
# DATA D2TeQx3Cgs+uUWbsF7a1ewdYyOT9RY3yai+f7/Mjj6On6Im61lP0y5rHavzY23T3of1MrbzGTbgSUadNU+ymJUtt+vxC6mzX3UGf
# DATA QvE+IctzFB2WbMlnpessnQAcQgeJ53NLCycKFqc3rI1pmqRMd6w6U2dBccL0igduCtq448WhwX2LeOyVu1+ra/OL1bYzjwGXVGDV
# DATA SpnrndXCqY+aafil2pPbyddU6E0rGXYKRauwF8jCfypd34jiOJCpIqtmj2cTgN5lYTtJWT/VEsjeACL3ghjPGUKOepGoMwl7Uwsh
# DATA 956+Vjz+26Pvj391/GtA5I5+v4iO+5el+Df68jU99eXxF8e/wmWP/vmaLv6O//4K4Di68u3RV8d/Z5Bw3xx9rRTSofA1hnYqDdkO
# DATA E3ftTX22zEPP1Bnvr8L90LvfjeUslojeq30lPPvtTeJo1KUOhL8dJJNB11j/8HzPxuI7hStBXGeDQ6brJnBpC0WUnQbZAoXqefBU
# DATA 9JQaWnctQu51CGiw1oTHfwtPwnHkshmB6RSumiO3vGguDybXp+gwuSCDU3N91ddPgsndC0US/DKAcrz5imxH+pfGBHFdYTRHg3FA
# DATA uc2K7sKBcpJnIZs5I3RuMq8y0ylt2KjJ1FA6KLJcdEXhBT4a3tDvsrW9NwupUUwj6tveiNMnBVg/9PS9Bz/10nGkSBk4/k5pU6ow
# DATA M7aB4FqcbkCbW15HV5s4S9vgdcHOLU+MQ8856+GSrAeNpTuz0fBSuBCvzmC4JHthI3PhlNbC1RkLUkmXZYYxFK5nQ7sMip2VDQDN
# DATA YZG4G43BoSJTxgzUJod4Nr8iWzrJcDhDd40FvHcwg+iww4IlRVLKl05kj/iTiB0U4v1DhqVqsz2N9FRkfL0XT/gUbZpuTLgDSCtV
# DATA vlkNE6MM2SeLcCJ+DvVrj+bKMR9w4B1B7yWf0IjmcfI6lIFJb1ryHup4ywEFBQubdwIv2C1yVkAjyIymBZPMkB/QxYF0cJ8yOe6I
# DATA 95jTPhJ3De/ljEbM0cEJebQugMhUlaBcdcw7x7xzzLtLZN5tOHqd6WDXOrP8ymcaF+FRPes8wwHwHADPAfAcAM8B8BwAzwHwHADP
# DATA AfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAM8B8BwAzwHwHADPAfAcAO/aAPAqfrVbrZwdgFd9rgB4y1agN6LgWby4
# DATA Soajk9NoWb435hRKg2Yuu2pBqxFEc2S1SoUKoLaGrGa9unXmVzcr7Uq9evZXV+pnfnW12WjXumd/dbV65lfXK61qrXH2V9fKz6ys
# DATA a41nVtZB7ZmVdd1/ZmWda9et5lVmeK5dn+7V583wXLs+3avPm+G5dn26V5+7cZWfWVnn2vXVlnWuXV9tWefa9dWWtd2uK0H9KjPc
# DATA btenfPV5M9xu16d89Xkz3G7Xp3z1uRtX+ZmVtd2ur7is7XZ9xWVtt+srLmu7XVf92pWaCq0zv/q8GW6361O++rwZbrfrU7763I2r
# DATA /MzK2m7XV1zWdru+4rK22/WVlLXteqiUvWqj0g/q5f1G8DZ9zTsdGu16UOssfaxWa/Bj1friYzU4OhqnMcfUBMSCy/v1XJB+s1qt
# DATA LMYkKAdeJQj6lfKwGnjlfqU8lxvtIArajaVI9uaZaOrVjKYu/hyLpt4sh1FQz9PU/VbVrwQ5mvocXx009XbU6vQymnpQqddrbUNT
# DATA D1vtXljOaOo1P+hUypdOU2dncLHNm/SNp1MW2zUWPfO2NsVhbT8zD0Q3S3HLlt30Ro0Gb9DE9kxmoi/udqzDzyqv4YNgm23LqFvb
# DATA MlYC3a1Q17PWpbiU0zIwyy66RvCxhH7YTQ5utehH/Cl7qhQ/L9GrhnCBrViCrSwEtz4PswA9tdVU71+TZSvz63jJ7gO11qtrmFkG
# DATA UHtBM093Ye5EQX55u7watm6X1Bp3+LK6xk5u9qs7qLqDqjuouoOqO6i6g6o7qLqDqjuouoOqO6i6g6q/ZFD1zGJU2g3bO8a+o1R7
# DATA D0X7IxP+uC3EKu6y2VYeHDKuXERFisOkG+0KuoIuyjZbNOrsmohMFGGD7FaCoB7wVczyRDYt3dVsdJ4aK8S5+g2NUgPSETG4IKYQ
# DATA ZtttSuDxUMFGsl/q8oJk2kXIXJj4gmrObaOU0lAdbZcL9doOjCMcVNm++fMP1X+3dv/yB/h3wsF8dHOvQOVqcdq5bL1FOD1UBXY/
# DATA 2w9H8WAQ3qoUxoMZTfvTW9UCJONuBZ//nKPC01gTl480nv7RbG8vSmVcZAEy7+Hd924ZbHwnigfbeMON+ez5cclvMk3+rfh1gda/
# DATA zvI/mQ7vXCgSgAjg0CQfQWh+/DgWqLxfqugg0TkrlghGBRG8gKaeCB3yC1WdgSbeFPJ8UzKXdQ0SJSFItiggPWdCpiFLV19bZ05x
# DATA Bse9FZbsZ2aiAYm0OXlaejqr5Du3MbLAcTWnkQOxD5UAKLnYkjccYxkIfljIC3Q4nTqnU3canbo5MRenWOcU65Zo/qxmWVwXJTtv
# DATA PEE7ZQ2tfJyMlN3dvKTb3gzSuBBmWqXdpsAWI/Bm406sgsb8jtVYtVgV02jnJenyaK0FOTpzX79y5wGGJupadMTFG67lpn4m47ZS
# DATA TMvIV7CBEybUAwMI1A2WcYqsoj9lgXoJLoWWrydjvp7q3oZYLLSmlNocEFue9STjPKFsRXGOoI1PSYlhXGsOIR/5S3ocnegpIGoi
# DATA 64WeyjxMI9UqpT5O9xvKLmK5vUzpVg2NOv2PjCHlaUMKinXA+4hSMc2HhXqicihmHYuS9zOMnAuPdPoz6BZr/TFlrpQ8njTkBlrB
# DATA AwsAVTy1hRxVOLMoyLiEQp/03OhjGbMSI8IMKqZXmbME6bocuau6eMkR1atzYzG5MU3Gim3AdSWZsJoc1M/S2RgjNLYcQ8+Z6lon
# DATA 6lr9/zR8InAFWIVsz2DyNT5UhaoHl/AgPMwsKhmAJPbwVXuPI3Zk6rgx2DW0TDEGEdtDDteteLou2fx+vO2ThDKtjcEw5DpH8wad
# DATA 8HfhQfEs216rAjINKq8XKDRUFu2iKGFha8wlx1JyYZe68NiQbZSgnE6AyNBp+JOeYGSCcpp1w4DOMGtlxlRjqp025VQ2UJ8zSA7Z
# DATA 6zsPWRNlsBdf4CwbdZyB6gzU0xiozhx9eczRlWbmNRdWthf4FxFmg5ydKi2G/p72eUCCraIs1OwR1utRKKzrKr/8fKmJngR0sLZy
# DATA CG6Ot8jceZU66PmWqo+j5TZ5Nctzm7zUUbNwwN+WtZfFY2LS+jsJ3FLyxsNRR0dHqS/d+cnCKTP24JPNs0LI23qWv3C65iBgeiON
# DATA 1sp+XdmMfa08zfmjjTE22JaLNyurTMsDM69jNrZsScPgpMEe9qieLhjMV97AzJujloNvDl8xXxden8Wo+Yt621IpFohdJxI+RurF
# DATA BYrIJCLTJWyT1a0AH3PtHadfpSloAnC/eufRUIDflJuGhszNjbV8Q0VE3s/PWlgGHNT3cZSMB9RCP+B1D+RFNv9gNTNFXBSZ5JxO
# DATA eN5wnIaouBr0ZqzFeaQ0R1mVno6umvwZYx+zB12eipkmMwzshJAZJ2NJMEtRXZUq7TURezAhI7IzXR+xe7ze4KWw+A919NRFmUmz
# DATA Be6FqEqcR8jJgwmrZicHI5qy0U/xEHLourIujc09mewtxuYlFCl23GRnxZ/Vip+vcs7P7PzM5zbgV04XLs/PbHji8zwOg1W7lpiv
# DATA q+Av65Vf+uH+07Hs2+FVcDJlomSWal/rCTzjLBjT71mXDMC3eRKA2d8YaGyM/g+4G0TE8gBjfUPGWDbThHmusFplx2/Kcb+aQazW
# DATA 4WWaxx9X34tSZ7ON/fZrGMWLKeO1dJM6fGPEhDLMt9+KXz8RMW0Fk88DfdHEs3ZSsQSn4Ezzqr+C/lFU5QL2hFB7pUxYH2nzuIWd
# DATA 1lcy3vRJ0a1uGlveyJF1YEPqGKjvmIsjdufYqPFpN88Zl+8mdne9lCwmvUxjR3UDJvV9jUrmDmIS8ZqF9kw/v4Bqs1YgHfAgnI1o
# DATA PoQFgXSaZ1Sb9HcBp2Gzi9cILMoQevYJyMxASEsvU/Lu4vJ+TPaOvUjGllD0tKNWMzxZj1BHHXqKmokNHqEAbA5TbFjjWQfP2MSI
# DATA 4rUKZShNwljRm8CSDsfSU8+VZ+ZAUb1jtokkl7GWe8QgeRa5yFmxSx7N4ZiWcJh4hW0exMRMq24SCT5Kzfw8cKIOUMkoMxgZ2pkq
# DATA vI8ZhU7mZL9osyYLmD1L4w68PHFiIbOP/tvxl0d/OP5HUK2P/nT8m6Pvjr46/q0Hdjb98G9H3xz/dpGe/U9H3x/9me77+6Pvjn9L
# DATA dx/9gR7+d7r3V8e/KXj06Xt68vdH3x//GhRtBC0k7V/R398cfcMc7S/okX+lW0DS/qNHd4HX/RsK9hsK9is8ffQ7itYf+UkK4nf0
# DATA 93fAch9/4eja139CSJ1YMoyKIMsJIktzp7iv6lAzBQhvwMvAvFr+QI0QobZpC4IEY+cUmXHjQaR4YYp2Rb3fREPtmQ2WGa1rKdoP
# DATA 8RD1QZFDZ+fme1n3cNXwbKtELo+YrWpVas30+AJXzHT+7nYUZt316/SFK2M7orH+IlHZFC6zq2M9kqmtFQuTupeUlb1BoV04Kfte
# DATA P4FOfQiIOY2pI22/Ugaz20kRJbk3oXJb2AMuPl+yWKiT2o8GtxHXPm+TIvsutb1UYSq9od6ccpr6t9qCyVrTs2Jfnxh5h712w/o5
# DATA h3WNtz7daP5yeG6vcCS/yIF8o3H8VMP4lYziUhNN0rPdvs+0qVwGoNqkUbaHrkoed97K48PlXJCdlJSGPZbKCKd9SUMPGyH7smQr
# DATA q880PQ+FTDvpH077w6zArL2Qoc4NhSzGULwJkfr9xDPRFfCuZi5zbEaJJ61mOZy35N3lH1mgOxUyMSs6yxKW6lURUDpNxmRt9RUF
# DATA dxq2kWFywE6shyxVBpBN+dWJU9Gn0FnagTPC8aUdX9rxpS+RL73RkLLRfGVDw/dqbPezmO4XYLk7kLQDSTuQtANJO5C0A0k7kLQD
# DATA STuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJO5C0A0k7kLQDSTuQtANJXxuQdK1SDYPgjCDpXrVX7gXPEUjarDhv
# DATA RI+28wMu1iDo18uV/Wq1/DZ9/8V8PkZBawnequn5zVo/qNX3m8BbNfOPdfxuo+vPPzb0a4FXoUer5aLf8CpV+uBVm8VazavS/+m3
# DATA RrHp1aoe4Fl+sdrkaxXcHnjVllf1cTcul72WV2sWK779Vt4JmWdbVbtBWC8vY1stqRsB4tPY9yvzgLZ2ve23O8tCqS3A+GxKWjWP
# DATA DJZwLYBXPau+1TzJPAqDRnshhpVK/fwxrPjVLIZB9YJj2GpdQAyb9SyGjfrFxrDaqJw/hlVuEpdUyjVqJOeOYa1aubxSDvzm+WMY
# DATA lIPLK+Wg5V9ADBvNCy7l04D0ZBDSID0ZzyyQXqsW+NVWHqQ3j83jK+E8SK/XbUVBBtKrh0HUaBqQXqfR7tIc3YD0WmQdV5uXDtLj
# DATA 7Z/FddZ9qTrHp/vcemiRRZdzCfnN/KxHZwLbWHDZUt5j0+N2sdKN9nZyIc8R+t6KaFyPw4LEfd75XWXXtyx5M5xvfv1ehcyTtU3X
# DATA 1ErafGd/btVKOoLx9MajnOVuHAs4YqB94dgYVjzlElBtmQOa/XBWeMoLtojnU7UpXxooDMsr0cDyyvLtUAuvKCHWZLNas3wyUXVj
# DATA sEuYrOKg01oN3ctKuGCXyZpZxGJtU8m1qpFydq8vHJ4KoNavnEZlBXW6+aiDADoIoIMAOgiggwA6CKCDADoIoIMAOgiggwA6COBL
# DATA BgFEXVATxV22TgshDn0WIOE7KbAMW/m25AefDtuV2hJ3/9dd/FhEbbnNgYh4xK4a3tRXitvPy4VKoVaoUx8Z9+Z7SHXbzo5+3Nx9
# DATA m19nKuL2qBCD/zbS3d6uesLq9XZuj9bmEgByesTK4qfeI6Pk0907T/UbpCejK8rOfaq6M/oP9Dp7jjHG0bHtnc9yOXmbDwFrW5Ez
# DATA dGcuVaPdO5QgPn4JY5Tn7Wh+fA4OSSjJyU+F+aOguVdSELwdNufy09APt9R5P3QUWa3cpVGXJWTllDHVR2HgPZRDx0jCmDpYxtyZ
# DATA hE3Z4gVy7wfq7Tti+S8vmxNSMk329ga5lBRiaueoRZIkDvTn+P6RKQIFVEx2uVZq2z/tQOcRyd0p7OV+eosmEVSxExqyIsqYUedQ
# DATA Co1fQ28rv+Y3y7eq1fLtvdIe3Qtj8We44S4b9ds4tVBQAco2dFze0XdHT8fJCIJt4eBhOBw/TvLPlv3FZ2+UynVEiBIyoiLa3kNg
# DATA +ovcDSW9eMQrm7iTPVDb8ikZby8LsUHFJAX4QDKTBRMBd9zGhxs+MxuTntfkIuXE619+1LzNdXHXmsigpAvVMlbgBAAJN0rCde1z
# DATA NSdhZXyNYNTV4bOs7t9WVeNz3QZ4CjzFdiMuwrv3dg/iEU2sSnyqnOvl0+kvf6kuHkTtJ/HU/kl6i3s70z6N0979yYRrtxxJt8Zp
# DATA pI+zSOrBL3+J+eDdexSh8CCMafbH2Yd+eohxckllPmUrSsZWI5L+URrK7c95tm/niZSRxDlvXiweXxfRI1HggfShnOJuR15E0zTd
# DATA NqnfMVPZJV0dn4+LBzSty3V6KDLzmAx5O1YsKVBVCkuCxBo/PWKCsp7jrH1NWr0EIz41c6jWadk4LZtlWjb5g9ZO1MaJ2mwqarNS
# DATA gPyyxG7uY92FR1eoTYwiW7ZFC988OwG1q1AZF1OALj/GB28bxZHeHMaj2TQ6ScdaP2s6J3PBSC4r1fB5SWjZG6I0oSvrJKz1MV+K
# DATA Nh/XhWL8Iboszu+EhTOodHgBrS8rTVycFIDcn88Ys55k5YT5kc1SXrKWvOEpUJnvzGeE9uBkWWFuzZLOD/pz6tbr3+Vv/i4/n814
# DATA sHKqd1U2f1cl9y5+sHqqd1U3f1c19y5+sHaqd9U2f1dtQWr9TnCqdwWbvyvIvYsfrJ/qXfXN31XPvYsfbJzqXY3N39VY0H+/0zTv
# DATA 0voqpg2vVFe3p68vgJi6HioE6aKViKzRhvq+J4JWwtEZmspJByYjJGYPwCbzJH0IqaVJrsuTEPyCVy14AQ9HDVC0ohELqXrYQcBB
# DATA C1B4aEhgVsRooFruP/XQvzLMwJL9Mt72TFWKhinMG7QiGAZBhClW4+n1wDaQMn/+xYQctNVNndZPndxM6cWcKZ0WxPrMZUF5c1e2
# DATA z+syEJ6W/OYFcztt8dKlsM6VOFnWEOSTh6alChcFMuNrsLLXQBz1OREL3FDe3Mt2DmrjSryWer4sJ3Yod2gyDRVNqCQZQ+uuUmgN
# DATA JyxyBccoGUN4mswqsq+Yf8prLyLWOpZpPG/tgg4j5um8q6mAB1RBZcqNPKGnQooH9I597EQUKtAe2GQsP0kvZ0YOdPm0GPrpcxFm
# DATA H2tGzmnHXqVk+rOxlHLV0hlLzlhaZizluirnZn7p3cwrjaxnr6muaz5V55BlpQ/hARjRfbwZKdNYH0/QNCEDPNfI9mY0P2ZX8yRS
# DATA GtgL8t7UXIwCuKUMnqgpPtehOcdyzmpYFFE399G4qpsxj0hUukZfGcNm0ut54X4Sd3n1c5TEKbvEJ1pTW7qDDDyeJUwrupW8RzRE
# DATA ez0KTUTUU14nlaPEGHwHEpeU9y8ikEOjBU49y6ydUqOfTcVwYxk5ML+7mgiHGJe895TOtjeMO5Nk3GcHjMLHRWGH3fJ4nnIAutXo
# DATA vpZ74jN3T8i2xkipwetMeRRNxYxIM+nnQYKNLFPQfGUD3jhkqKHV7WmAXsm7i8ykoOPxWIG3EQS75G57WNjGVUZvh3KXXeYezkig
# DATA Lx4hdzT6XdLNqfIO6G28Mr4mee+HsGuEW7yXGNV5XGVzi0oCZrEUsMbOU6lLJZ8mw2QySQ6UvrdUf14l10XDVd+TTBxhX2cy60AD
# DATA hjHo4rvKDvFmaROGu4GmU1Fh4FOU5XXpeZPl+dkzhgWeBUDOgCw6noJEsBbFAlWK8AkGqSkPYX0yGWzDktokJg1s6qViGtLtPZxQ
# DATA R1Mw46BUB+AQBROAFz2JGD6PmkfZOJRCYvI0WZZ7qMoDkOgpMrMRBmasKSXjdD6RYk+dRAp6Xeo5r1whPpKjkguzeY8wos2DTW4j
# DATA rdXrFrXjGMPcSq/yOidyfqHElMKazMv8yvzKc77Wl9fSL9KsTOO72Nfwcok0moyFJcwCbkQX+zZeMHnIJWsq6xSdjtUJo6Vc7Ft5
# DATA 6QT7vlc3zPwLb84G5/TFv7iznwxxSW/rJskktfmW/3L0/fHfAkh5/I/MnfwVEy6/OP7t0f8AUfLom6OvFwGX/8IES+Apv/COvsU/
# DATA DLP89uib47/1GH35xfHf058vhXCpAqYXMdbyOwr866M/a3olgzHptm9Bufz6+B/otz86hOX1n7c9kpnWJIGRxKYwFo2S2V5/yowc
# DATA kZlWw+sgnkJdQ04Rm4nYbKRtFzKlMOqFDG+VAZ8tmFRmbsCgwCwM+QzqWn7lI95xQX1hPPA+IYuRjShHsszmcLoXuGqM5dKCuTyg
# DATA JdfL1Jo/6moqyKP8zais5tYHquZieLtImiUZqyykoNYwZa8JNYmxI1luUFoXDrK8q7ZWDah5HBYPwsGTjNREZjV4O8D/qGTB1u2E
# DATA OG5Eo+wE8mwKrxN2MUIYaNQoisjIxwI81ctDnhsoChLOz48XSJYn1LzVZsmy5vSsiJYnJMLxLN0Yf54xXsMszzq0vxSu2Ssb1i9n
# DATA VN9oUD/NmH4FQ7rUyyU5YAb0Z9h+LoNwuSSpHs1D6ROz50K1TCrJRSwLvM4ZItvjDsZZpJiTuyzKvPFZPTxJBBQofVMb6+Yc35Dj
# DATA Nsqh9jaBW+Yc3YiSSobR/mR3N7b6eQc0x8YasCgfpEIF9H6aZiaUjPxkuWGXd49iFsMQEDRhPOK1JUO7hLUTywuUZxiFxgtZdy00
# DATA pPKtdiMaI4cxmQ0H/YhjEXpsmvAGu17kaJeOdulol5dIu9xkiNloSrORTXzV5v1ZrPtzG/cOeemQlw556ZCXDnnpkJcOeemQlw55
# DATA 6ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCXDnnpkJcOeemQlw556ZCX1wZ5WanVwqB+VuRlM2q1e88R8nLJyvNp4Ze1
# DATA iler1z3KN8+vlgd+OfD8RvndWqPpNZqDSrPiVZtzXEu6t72Iwxz6rapXoYwO/GKT/m55rXqxFhR9v1ih8INfvFfzKexmMKhXi365
# DATA 4TUbnl9pFAO6pVas0utbxUpQrDbmyiSIGu3uIh+wStFufOoH5WJQ9ipN3ytPa9WmV95vNN+uVfNh1DvNbqOyGEaz5gW18qfFSrlR
# DATA bFKkKrWiT3lBMQoQ02KzcQJZ00RugaPnN+V1nXiC2VKHi7/OkfA6XLS+1NyJgApz8e0GzVqtdgZaHtdfTcuTpmDR8tr1IKr6G9Dy
# DATA 6t0oR8uLGt2g1c5oeUGvDtva0PKq7VqzktHymo2a70eXTsvjal9cbxiwd3/ON01FhbOXn1sBaNsgx06TRC/i3FS+Lvr/8Ida+O2T
# DATA 1hCWGzur4G9WLE+m8NmQPXnwdJC92iJkLwvmFJA97YBcmUd2TqsMVRg7Vf9sj1GF7TQ2BswgtmIbgR671QJXeTX7LsvXgp1Va8yJ
# DATA E3LCEO0cfM7B5xx8zsHnHHzOweccfM7B5xx8zsHnHHzOwedeIvgcpw2nEYra5qE0vrZuQGMEkeQQyw0t7U89Qx9DbzDYvbM9WOA7
# DATA qRTv6I7sNQrm6Ucyrfm5hw87Nwb5SsY1f6f0SRKPKIAP6T/woW4b8/LDLX3sPItLafoU+frh1hsLJ9JVADfwWZOi7pkdCjpUDX7S
# DATA bCWnEO4OVq85WO0OVL8kB6pPqxf+bA9as18yc6Ut4ogGOS3MvSTp4myxx35Cc8yWSRIIZI3O9rM+n/08nFHkvy9Yq33ZQfKLVm1f
# DATA fi5/qX77BsfkMz+t0Q+PRKAOpa1lJ1XlMBozjyOKQpoMIwjB8NFaqWp8Al6535jIIrqB+fPl2cnxAmSQydbMGjvPGaFnCg9w0uvB
# DATA Ma0PNIvuIQKXqsavmD98fhoR8YVqIgdyw8w6eTZiNc/iNKt53hlUzqBaokaXVSgnWOMEa85qR6201y5HyIb7dN0MyJIS7QrWwOgn
# DATA 02RvEo77lqj4M9NNuwCAJY3LbygZGmv0OqVmsRgDCOQCBYvV2K8H82E45syxxvxlyrcXolr8Act7S99ItREKKej5LkG4+E3Y6vyi
# DATA kRc9pXz00tGFywezaPE7o3Q2CKeiXn6okneAhI6pE+951N8NBpchWzxjTaWp5s7MWAN8rjVc7HsDUZ6GxHfXExF6Pc7R8Hex72L6
# DATA 44NokrIUE1aqmG8vsjDMNiqGMRnwszE1yOiC1agbWSc6Z0FTcYbgwQoDRAzuC5aInmNNZtMyCTLvmKSHtFaQNzw05of0NgZHmQEg
# DATA bUV1sxyUKcpjcmDXH9WEDjP1KRnQ5MRRukJaqgPAotaVsnSpoArE4lLeIwh8RyOPwSujDhWUlp/qKeoB5X3BKGQlqnfWkqZYeDrU
# DATA Wkk8I5rM2m2I5HO5MJMY1SQZML5YxgHROJrMIOTl6UwzOl7KvRnJC8xid6h0UzdDPb440w/LoHATEDcBWZiA5C1MNwVxU5D8FGTl
# DATA xOJZa2kqXgczLfrhmGHDIWYYtjh2GindPS0FOScWyagdrQ6p0EeRTGYsncepLQCJsXJwAH7STHAh8xKP0mJn1JSp76JS2I+WKD1u
# DATA qrbJqR3feZOXNrN4tw+z2RFzl9uzeNA1WnwqMuxoXHQbq8OjFoBeo7dltZ+BVfikLCxlAekfM3i2ucIqAn1mxXDPJouzsnuFhm4r
# DATA KXkIuHqv2UIAq1R9flU2RqiXW3eYntV+6tWEe9jM8MMaPMZYajbqPrYtE+XInb+dJqjqMMNb/Gn1nZ1BPGxzRPFh9X3UMSfYlEV3
# DATA 3peP2b03JW135jDl2taU1Xjb1MSIssbQzJUuNgNLs1dnpDPLOZx0zfSUNz/IRFXlYz4f5sBcvJPadAeys0AmtjO+veY9GZpkzMfb
# DATA ZCqUI6t3HsbMaupGDBOi1loVL8EwSaeDQwW/xE+wEo0UO6/VCK8rHk1lCIxEDhO7JNN+ovREQ4Gea/FYBoqPjNQstVyeFmv3tpLC
# DATA 9GCZKetQHdS62gysnyIDP6A58YB99/GkQ9PFLAsxR6WOASguu6NTsxx4Sqhb+ERt0aGe7B6vErBtzHsrYbYPkzYeod4vkjpNRfEk
# DATA lUUzRQHjsriI7LJaySnzq7U2v0yTkwz7CSQ/qV3sRSar4E3ge/J5ZBBckpEl7wMaMwseq+TFZIQdKv+TgohRdy6UONmtIu4wzZmn
# DATA YYMxblH3IrLKdDynzKjG2oxSvZhk09vw44g5H4+sWsWvpgpxQLFM2RETTgZq9VT7ZuBEwDa4EFq1stLF02z8DO/f3mHmL4ywBIg9
# DATA +ULOBXCM+zxuh5DUZXQF3/RM22Rwijb5LkB06NOo3RUp0UWBXJnaZl+m5ibUOpWR1spbFKaHWNzTRDh6hGx+kR7m/BRbJAXGy5qR
# DATA P8sK5lc2r2HvJlTENEYOokN2E2R1bEC/ZBaO8u6Kw49mt9QE2ROXGWvIEOrh2WGlF1HVoqhYW1AHxomcRNVRslbEBQUa4STuLM23
# DATA /EAse+vsgdhckWy4836id8Fp5Wk2wdTuNDhFVEkqSrTO79JJDLEXxQGRscTG0RRoXhsl9t8FJOYd/eHoK4+xXqB//fn4vxx9dfTn
# DATA o28WMWL/z9HXR98Wj/4EANjxrwEg+3fgwo5/Rdf/7eg7+vt39Pf3R78/+t47/lJCR9DfADr21dGfjn9z9O3xl/Tvb/EmsMjozRTG
# DATA VxTCVxpM9uejrxxN7DmgQI9k5Qf7eDpKpT6jQI+jZMz8Rgas89BObU8MxG4C5XP2NmKgsVzSSgyX70IfnQmr8xuoB4lFQp6dx2up
# DATA Ym/BXGJ2++jQ4cRsH4rqCK6aJpYvkMvFiMUjaw33vq6l+pdFlthoikOApo/FVxnposlF8sTCqSAK+mFKwyksWLJ0k17P4cQ2LbUL
# DATA Z4rdCwcdrDpGsgB2mAGqwyHvtOclkAGvk3g9TCU85sKx3J9Z5QBJdziMePKLsYTXEeNfREzf8LpxNF2CETux0q22TnJt6dkxxE5M
# DATA geOIudH9IkZ3zRM79aD+UiyKXNWAfsHj+caLIacaza9oMJcaaedBtt3q2Tedy0CJ2WkVx7DawdFP6DksPuQTihSYWOrCwiLRmqS/
# DATA Awb7YJwKVYmTNg3TJ2qvCiIQj3ByDMf4VJZshhIDwEiG6n3wuhSsqZuRnaTayLDe0TYB4FMJNtrBJsDaVkwGwhK7YAbdhXi6zB5Q
# DATA 1gCDj2AHYPUqfUKBmXjEcI5zbaL6NcAubewhm00nsZRZMupEk1HqOGKOI+Y4YpfMEdtopNnwBMaGxvGVGfln8z1egInvaGKOJuZo
# DATA Yo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4m5mhijibmaGKOJuZoYo4mdn1oYp2gski62pQm
# DATA 1uvVouZzRBOzl51PixHzg6pXbTU+LVbLRZ/yp1Et+kF9UKwBq+V/6vvVYuD5tYrnlyteo1JseLgLd/hNYMDyWdfttVqN3gJhDICv
# DATA WrnlVegdtYZXaxVbdKHiNesIMvACYLw8H2G38LpqKx9sUG92m70lYK5q2QJzVVqBAXP55Xx9aNcatWhJAEHNCqBqkb2ai1WitowM
# DATA Vmmc9nkrX6rVhlelfKgEXrNIf/n+sFLzKY88ZG6Zs3h1QuxSpDtrQdAPGs050pl5YIF0Vj8Dp4xbhuGUcSOzOGVUjxqNcANOWdir
# DATA 5jhlvUq30albnLJWvdfIOGXdZqfWrmWcskqzXq03Lp1TNo6mJ1LKML7o+zbAfFmOsiq7yUpNXh7DkLazSAIzIWvMWW6mWwt+5AX0
# DATA pxKw0zGH5pIclRBUhDdzqqlUGcdaxUx3595eqbEvkN14c7aNeJ7WILx0ugq5+K0ZwnO3aReYQ3Y5ZJdDdjlkl0N2OWSXQ3Y5ZJdD
# DATA djlkl0N2OWTXS4bsUhaHxeHqhofp7nvhtF/qDRKa2MDs+3ALh7Eo9T+GSXNTXePzUbgoX2maBUOVWg1bnx9u3R3TBO8pXJTR4JBy
# DATA 4waCvkG50puJXBgfD+tZOlfqrBWvIoGUBaSWPswVqsNZ0CBDkHLsJuRD2jigYs5gid6fo2y5Y8enPXbsjhu/qMeNz4LXugbHkNl9
# DATA p/1d6ylbImBl4r30qPISvtZ1Obz8XJ3huwzgVv649QWTtuYqw1kRW5YjNTtErnI6w4JAnlEE5JXqCmdXv3rnTZ7gs66c1qHj6gOh
# DATA 0JHSm5ODsKb6HIT0RDs5wGnnaG82gHyflp0bQk406UENvzubcAUNJ0Mtfa/OxPO7dQTukm0dk/HL22Z1FDQljLKnh0XSNmtxTuEn
# DATA 8nhzilgmWGodcNqgZ8dtAScq2xFe3CWbbDZpG+HJl+SopxWGs6ucXbVGrM2uXE7Xxem6nNagWoPbuhy9l78eJQfo/kVxoB3uicYa
# DATA JDfUwOZfvZzYBdC1eAVC7QDR13La8DzRp6s/HUFvIVIyLMYt5m0/2duZIwGNeB0oA+2oIEw3pb/ncEiUaOqSoSczjFnetlxCn009
# DATA i2zJEeMIezmzH1fI2YsfAkAfW7BljC2uNNhvnxhf/XzWr+oLGYSrWV4WZzvG2K5jR3lNhNlTwpQmuKszHRtk1AlxVY+aqOrvOVzY
# DATA 2nj6a2I5R1BS60torcrpImrkXNUtShIq1Z1XZa+piqdaY7S1fLNL0rvE+5ICGn8Vs/WmBHE+CpTFbLLaty18pPTpFeIlRLM3+oD3
# DATA 4XqyGzA3aNZKiZ7GouLCwx16HO2C+nRGvRC0ytPZ3l7EHmgAI3hlQnUQyQQYC0CVWFUaozAHOgKgYqBpXMJAY9+4ancQUCFTfsb+
# DATA eCoa6MFAITjcM4xYKFDBOE1lJO/GPZZOmYr+ECs7e2orb2TiI3L0kCbiaCxRJ8okiVhWGZ5GRMYLx1TnMMBtynZ6QYzd3AjmzF1n
# DATA 7q40dxdMG2fxOot3tQl7TRQO77H6HjSLexhk4hHLmC3nO2m+bCYFOImGMSM6CqtU994UpuDCcMPCZnuzuAucYTYwUmjUXrszAAh5
# DATA eJs3gfPQhAWBQ3MfjeuGaap9TzzU/5Q5ARjPJgkNHeFUj7lshw+pgc9gQik7INybRBpfuThkKv1DCqlLQ7VJDlxVCwMnSwNCXIY9
# DATA RxFrwnnhFBWaInzbprZrMmT0lLdH4R0xoAaU6ytmBCLxluzz/ibF4NT83LFmeGEjp4BCnkaTToz9jjkIqmQ4FwyL9llChcpLVvLe
# DATA AmeLu1H2pjG0qw+bi+9igAmIlXDXvRtNuZ/lZMC0Cadz/jYcXDOR9fhwA9gn69J4V8tRmv5eJ/IDzNo0e0f1/VCZLIjmngYT4RGs
# DATA P1JBD9IC0zFSQ+3URpeYSe8jMPSUhzDB1EZLHlkmPCS1YWlH3bgTSgkqfCaycqGmW5iz6CmNeYPDdal8n48UG/OL8SU6nXd5p6c6
# DATA JDKbFOBJZoXxoS5+nj4qUk4M+IkyX0dQ4lPinxYjjZOUV6oseY+i6AlTQuCWZZ4H8pJvVdVCK1bm+DLsPxVuCNQW4SDWjuIw5Ult
# DATA uDdK0jhdIHOwIXaSzvfjhDomzs+sC+JWc2pSNPu09Rh0IZxoy82tGgPc2+zEvgQy9HuovnofDDXXEFVX9N/1NOUSKNH3cs5ytFkq
# DATA b6HLXgIp+t14yrOyCXVbEIIUKKRi1nDPKQKTlwCLfjCQd6KD5NRmjYunWd1LAEXfpQ5It3j0Ul2jr8tFCm/RpHvB7OQXff5mcXHo
# DATA qWlqY3H+GRCco++Ovjr+9dF3x/949LV3/AUQNfT1a7r8zfFvF8k4/8Kom39lqE3+7qM/MiXHo59+dfS7o6+P/0GF8l/BxaFr3x//
# DATA LZ6gV/2WfvkzvfCP3vHf5Ug7FkzHoXGeA7Iwg9mMdq0wsuD5BdKjINtQhQvc427rAFDuA2VR7UWsGPwEDmfBCU81K5EhozyIgiG4
# DATA N1hPwHk3Cnv8Foe/yc0xub1fNf3GKozLQ99I0rJuketOj+dh87di5DA38lRv0j+c9ocXibvhTbY07emjxnd5RgDkHm/FxO0Oe3Ni
# DATA iV047waT3KSNOSbXM+2xxk4RNR3m/mUQToZqaSqbfMapuKIX9lCLfjrbtjKXoNKiXgzTOjJd4OBewN+sr3+rjY+sHT0r7M36mDvi
# DATA jRu0TzFoa7DN6cbql8MXfDXj9EUO0xuN0psP0pc/Rkv1M4k2A/LVtYXLINWY9AghOZ1PiN5/kW1iYHuinww1DMYqE5np0oCGwS7s
# DATA ckKZgm6IFKliLHeS2UTYFNn4qhMuR9npJcgrDn4zbo2a4ufG4NA41/XobcbtlG7szgaR3hLJS1jwKnrpOOrEUVow8c/YxcrROojF
# DATA 9RpRZxv2oulhzhWo0sE4XcZEMwq4I4nKJ8gBahygxgFqLh5Qc/LAsdGcYxP79Wrs77OY3+e1vh2MxsFoHIzGwWgcjMbBaByMxsFo
# DATA HIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWgcjMbBaByMxsFoHIzGwWiuD4ymWouq3bPCaPxe8FzBaMxy82lJNNVK
# DATA 06vWyn3Gz1Rqnl+rvl0NKvns6PSa5WCRf1KjBFRrjZ/5leo8/6QWdGrNZfwTLqV8MNVWy6vUKv/Jb1W8SqVMfxpey//UD5pe0/Mb
# DATA Fc8PfHpX1au0qp9W/HrRr1IZgphTK/p1uqVI3+imGt3k0wO1/1Rp0aMVr0ohVJuf+vAi17wa3VOt59JVi5qtenkRECMRKpIJX/T9
# DATA 5tCvUb7gRfUy8Dxzae20uq2wsyytCj1DpRiT+aHYNbVykLFraq2yVYFr8uVwSW3udqJ6p3cGdgxXZMOO4TZhsWNqlUYYVE9kx7R7
# DATA 3V49x46h+DQ7bYsdU623OCBhx1An0Qojix0TBO1q7dLZMQNqBSfCY+A0+jy71VBeLI6LSt2iY4+dexX6t/kj29xusPmQBXkyksbm
# DATA zfBmO9lbvCwWxnVVWrJ+ShaWh6VKry5/cqF5yqIxQBkeRU3vnyPXSBHPpZjChGXkBfLHuEYl2U0YV7Y/x7fWeFQQDcown/6of7WF
# DATA ydYrD4graTUblGU+6/Jz7KUZsTIgB7VxUBsHtXFQGwe1cVAbB7VxUBsHtXFQGwe1cVCblwxqow1CLe2ztfPautGM4Te61+dTF+qx
# DATA AvrApV2rp1JmVardO7HuvXbZJN65jXb+4da9TM0Lh1UsOZcR5bDSdMH0Nc+sMScf3Llhd27YOvniTg+708MnnR5eqTV5KaeKX0fN
# DATA hdJcFrg5WfxM9ScuQC8dWnN480EUPeETjtJmz6g1l40tF6c2F0UDpcrdllUSyhCtPqgc3ZcgO6fPGytw25hKtTuB9pxHc6RocHgJ
# DATA mnPvjHCoeSo9bKqUsmEv9zKB6ksQn3vMri+VRjJBVG9OdYLGjiLUr7uXoDv3UI4SwwdIppxKsoELXEq5svbc+zhrHRoBOrQ8GeFg
# DATA spB5ib1Qs0l0wepzygNjpOMzTcacMkB2uFUnxJyapQxDFzDN9SCWRH0mCi8S8JBQnTusz71RKVPX7E4OdUZnqIZwcABu4TBiCXnc
# DATA goUqMjQGg5L3btwzzaEA3MNgsS0qFdURojLx+vTjJMKC1eBQnuTu5SBMJTqaKKTUarkOiso7Ghu8uaJdTZMKLLHvqwCodVA0pb70
# DATA 4RucqBPx0MmkR3s0pKySDNC5oo/7Uzc5wsl33mZA4wlLAdBIPS/xMzdSPYxwHFCd4pZJq9wh487JsvHP+cljh5x09ntmvzuL/YWz
# DATA 2E+LlHyGOkC8mG8WotdzJN+MWf5cwVEgej7yeC/vGojkFcsHXXs5jcvgQ2YiRxcNh7TloM5KhrQ2Kehp00McqzLVQSZ+LJyihKcq
# DATA cwWJXQ1Simp3I4iNr0/kYdAAsIVOQxvveoPZMB4lM5oiGptoRJU8gYjNOBoMIO2OMbSvFNfJ/hqVvJ+0RW6fDBNsuoaWUp9MUoU5
# DATA YJ6NfrsdjbdgoPFdnBgdi/dhF1EQFDuqvFRrLLOLTT4+PxLxNoTDFFrqYcoS6tJCtMbzEBLWk3XvZze0l3v3W9KCUjIvU16KLnnv
# DATA JelU238iLsTsHx3r28ggaV9gL0H5hvpr2AYQtqduhKo6y4bMx+RFF4mxegZnqzlbzR4ZnLP15XW2rmZOPksJx/d4sVLXZyXAxkev
# DATA LSglpPUYjrAP7TZpP5nzpsBuBAZMshNNOw5L3oNMDBCncESlzaB9uAzZaRBa+oHs02TfQS/ueClN9zvGs9LmrWSZZqBoLm6oAckp
# DATA FsdH1vhlrQ8xGYWTieYJ8eESvAdenyVGojrjuEi7VOvcqKT8SfnJlCdL/5gBEc0VznFgRyIOR55W7qdkMLBSsJQAaRbPuZrI51dl
# DATA S4B6uXWH6Sjtp15NuMPM3HdYfcaIORjopdEY/tBEWXPzt5PdwK0qOVh9zx6bPYzM4k+r72yzncYa2ROxUvSdNyVVWT7IeKy9hbIC
# DATA bfv5MDSscRWutRktz2c46RonPC/4izte5aCVA3MgKd4ZbFq/LKVzFZrMOCfumgTMx1jycswG2z2IOMYTCJmi3mdmK+y1otLkLIjE
# DATA aBEzM61BSsPYMOlG7Mefwp6F4actOEEp2c5EOCCNVGfEQkPayJ56v6ABt2T7Vzf0pXpmmxxbGvmkmKzREmYAvGK5mxsRPWM5Xedt
# DATA 2VMVT1b5TllCj1aXkK7GUkiPxuyDzZcQNWPuSMTjDuwLtDL7ZP+IGzT0pK4rq99iB5o1EDwvqyAitZpAfRRTDpQudjAqK+X8ZWOn
# DATA 4PoXzINNC+ZBOBmwqGw4GOqCeZT0GMY6olGNNVMPMMmjEXQvPzcreXf3kxgzY8p749Yv2K5vLpUx9S+YnHXVLBHTw3OXhx3xKyuP
# DATA rO89ZXn81ery0L24lMdfkcGy0JHNOp3ZgNVksQioThKqxqEnq4qlR70UryTgPDYNGSXvbWpdhwUqQjJDknggKsdD7sWS4VDkn8m4
# DATA GApLjH6KkYNmvfj8BZWl6PoX08NNi+nhrN2e789eZxFr1ZtFo0+Sw6wH02JcJe+DmKa73Rl19HuyFGXkk/WqUGbhgalNedUJZ0LH
# DATA O3dZ2NG+/p3Ym5t2Yq/Hky7vGBjBAUSNY2Q1nr4oXvdnw7hbxEIhS4yr8uBRJ2XDHtJCU1jmH4SaS52t89u8PZSw6e0oJDKe1LYJ
# DATA aCHDPXTuclpM0JlKK2//yTZG2/4zVyTv77yf6A2HWoNbTH6xuHnpn6GWIc1YkB26lNXC6eUw0Z5rj1fGQkv7SZRDof1fR/96/OXR
# DATA 745/A1YZMGb0+VdHXx/929F39PfvGI/2R49hZ98c/en4N4tgtH9mjNpXR3+iZ3/v0V8c4NE3BQrx6A/0jdFn9L/vj742L7FJanTT
# DATA n4++xifFUfs3UNHwfnnv90f/fvyPjor2HEC5zTYH3vKaTA80dtWQuSFeLOTVAs+MeJtVBBNPswAADYU7gWVkqAMQOAM60DHoBoro
# DATA SvV4MuU9Y3iuJ0tYxikAT8dachqU5dEUxM53+DTb18ddxFXT0+YL5PIQajRahINkL0N88Q5Dfvk8h/tmL8666TfjqYXvuDiGGkxp
# DATA dW4DNTSREZyzweHTTi6tC+envScYcK9NxgV2dNG8v0/jjpleFrSRlSY4DIWMhCGLZKK7U3taMb9RpPGnUEmJss6Jdb4KZFPJcuQk
# DATA Ys8iE2b1MYEhFZHgNTBYTRfYauvr5WojZq6VPSvA2vroO8CaG/8vePzXELYzDPsvxfLe1Qz5Fz7ibzTgn2K8v/zhXipiPulmlL9e
# DATA zecyuG35hPMgyRlioGMm1e1DhFSQM4yTmbxK4joVoFM6DLHwZZbePOmX2lEKl1Y0wdIkJ5oG6uzYgopeN+4Zthsl+9BTJJMNmW0T
# DATA Za7xthocWSGDgv0SUecJxiaFJuM6JtwrPjXMO4GENhenvIcqnQqNi5dmo3QqpgLyJbMcbiuKGehZ0xmFMAxHsx4+T2wjQXle4Sdg
# DATA m2ZyWExGDtnmkG0O2XaJyLYNRpeNJjqbmMRXaNefxaw/r1XvwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7c
# DATA 5sBtDtzmwG0O3ObAbQ7c5sBtDtzmwG0O3ObAbQ7cdm3AbX5Q7VTLZwW3Bb161HuOwG35NefT0tvIVvWqtean9aBYrXvNatGvVgb0
# DATA T6XiNQPPL9MvVc+v0Kd6sVId1FteUPdaZa/S+LRao6teNfBqlbd9v/VpsVmsNryKXwzmsjRq9Srd9hz0zG/U6tXaMuhZa7HkKmWv
# DATA Vg76QaOyX62/TV/zLzBh5SlsFUpBpR54Db/oN4fFWsOrNb1Gueg36EvNq9W9epO+bBwxv7oQs8AHJK7xabFKhVpEXtTfowAQ20GV
# DATA LuRocbyTM/+yqNeor8DcqQrciSd8wu6pVPpKhn7zGwySY1WDer4FmGApABg2njxdRtZ68nCzma/2vR5/1/0vy6Gy+Gu1SfWGwjgl
# DATA No6bkcbGSYu0sHFR0KwFQR4bRzfVKvUcNm4OJCfYuFa3lWHjap16EDQybFy302n3Mmxcq1ttlaNLx8ah/Z2Mjatqo0BMAv3MCn4c
# DATA kjnnXwx+5NXoT5X+1IMf2UHM8eLeGdJUYlrAVmDE13ufFTvoqx1ze5oUlMu355154u4pNPcPCrxKtmJFTEUD8KrxZ5suFZRqVl54
# DATA 1Uk+GE/vp8gZJGa+hF3V2sWnvZx5pp3KpAr98QNt8rOvKJ6ShdXJgey0D5v65coCfq68mi9ncr9g58AaU+SEBLKV4DhyjiPnOHKO
# DATA I+c4co4j5zhyjiPnOHKOI+c4co4j95Jx5JTFke8A4hGFvwt778MtaXOU8BvyHYownA1sYn649TicQIWWH/HkZjSvG3yBqsWb2Ey3
# DATA 7e/coNzoDEsf0n+ju9Yp8fs/zR/D44ffC6f9Es/QtzmcH/ulACFkx/uWHBrPlG8hxWW6fY2ay46tuEPU7hD1Joeo7aNN7iy1O0u9
# DATA Ri/52Z6xlqPBBX3Wd8lJ64fmXKDUkUJeWc0c6pUDq0qQhc8Sw44+UDrMcpI3YpX97PDkODzEZFoOT0JrZWSdnNxYA/lNUT1uCyOq
# DATA CwIVXh2aDh0dgdM93kT3uBOms1DJpuHT6jvRpVLW4tYP5OPqe6mD7SYJZ/RP5OPzoICc5cUpRRDvrRZB1LkqIohklE0Ou9AhCkf7
# DATA YZopIOLkJDUvKIh3EnabzMZjnHvGRgMcRvMmIguZAs8hh9nZC0ZNLSp51KpjHB2e09Hh8bA7OSx4UZgeckM5v+7hXBquTKLSqn8X
# DATA pxhqarLSqYbtMJnBjMzKpjNL+1RzIxbJxRl0OUIdilw1mzmZEQGrEnaJYBhQUH1w79BFZMrUSs+Bj4fPUD/gL21r5sm51KmzBDwH
# DATA BfPBxgXzkKp6EW6VQ2iAW8qhfLC5QCUyjrj1cLPRDYRBMig46o/QcLRuKM4RQrEKiuHRmG1DZLilpiGCA1jbkvEtHvSTGUuPnl/f
# DATA NZeUKyulM3du727aub0XY+cMNDxmE0sZmSYoNOfDrsBpMtZNpxdPhhAnnY09VTDJhCXY+FdRLzmgRE2StnR3kwhfWTdsNuqTUQV1
# DATA A1vG4zxFkov5lZWINUieskgery4SM9xKmTyehPFA9FJCMmtModD3KYwT2G+J5HCXpj0w8lA1DQ1zEqrmoDSrARPWSjOZkkQm9iYi
# DATA LINDUXs7d8Hko3/928qjTdvKBzInpQlqPKYqbAoGtRuWM03dZYsQDGsexnk6ClWPccrjPab54NFiY65CZqWiGa5Ewqcsao3Shef0
# DATA 3EUxF+OXV+v4RZAT0Y8775bzbm3i3bKrmPNuOe/Wxl6slU6wy/FusfCWAeCF3l6SiCie9m1dW/3adb4vHGnwbA/YglNL6KbYMKL2
# DATA IetrOW+TWp5hNNMI++95oqoWSrc7wx3l9tINUyalKEUJ1TxvurLsinH9VHh37QQ9N3qxYcwGUoW3VQ9D3vKqN/JGY956XfJXO8h4
# DATA BQm1PFHlOjaqZXk/mbrRxEw/uOCa8hWhF3ZP95bne53haj+WXwrYgUCBxdGE7i4FufsXfFnKwjKOQtl0Q0Hc1/KFc72sZSah/CgK
# DATA fLhIp0p2X9mmS3ZJmngs5tmYxsOpbEi/KUGc0wASIwWDkdXebDXLxxNxvwoxFv3Agkr0gPUaR9pLW5AZA9tw7BUJ98JYdl1hS7xg
# DATA pGj2UPIM5C6rpyWPC63Ag58FZGHxyixI6FWm2jrG62BNjeORYKwQJlnERoIQC4qsoIZDY5B0bB9K8xRhvhAKlPYqYjrbA7+Wdwpk
# DATA a5hq2jrSEpSsV5nJTs7YQj30zHYBvSduzDaMxssiq194wzMbapzp6UzPTUxPZ2u+uLbmSuvwGqpV84kOc7pg0QwbWGboWzA7OVag
# DATA kE8iWSZMtRWaPcSyS9z5Xj916+sv+cp/yzmdO69SDzrfsPSxQIRrjnA15YSfdWZRLoQD/jYvwj1/XE+aaSfBZEHedTjqiPlt9K/u
# DATA /GThtB/v4KNCXBA3t57iL5yWDYTFs2Mr2h6bg4MfhIc8fYGeszHM7vGSnUyORmZREP7EPQppfCjLizJ3Ao1wHO7z3KXkPeTlrKm2
# DATA oNQ9yj5DrYTLWJxxbPDMr3WFWA8nK03TOjaqBPOV6f7T8QChpvFTbF2XZUip3lcO97hy4ynDlFGF2o8GezPqLmxY2b8cf3n8a8aS
# DATA gSD2DX/+E9BljA37PYhi+OX4y0VK2f9ufvzV0bdH3wBF9u984ffHXx79CZcK3tEfjr5iFNmv8R038OuO/57+AET2O3odQGbf0M9f
# DATA McrsWwrgO/x2/AUF8y1gZcdfeBTGV3Th73ERaDTHLnsurEOkjade8IewXLmuvbdAJA0nT7DKF46iAtweNCud8NxxHMr0B4MMzVBx
# DATA VJrXkKCX4c1GHBhrk8/iAbNRqUWHvJuTJpbhVCCpEbbqU2e2llomMOlIBkoHLbNtRavDuGp02VypXB65rBvLOczU3PmGusIVdYFe
# DATA hnHP3EmVTmri5ILhZTzPj1PegIDmwDvDdFQdwWyzUrtwipnubHoxPxcOxKmUdvpRdybbRAbCjofkB4OcuRfzWO3V84PiMB7B1g4H
# DATA VLmxj+S29vQyOkOssElEAQtIIR6hCxYzUFlG0iYHBt+8adVcbeLkm9qzwpetjbyjlzkL4MIsAM0tO/3A/1I4iK5y0L/oMX+jIf+U
# DATA I/6lD/hSH3OJt+ll16L5XAa3LJdiL5I5eioeKaZwe0kvv2+Ps2Hap1ju8boJGl2MfZrGMmLE0TAcc8Llteij5NwA1U5Ql7DUopFJ
# DATA sl+TR1yp954RZ0s3xJZxzqlK4VF2zPA6GfABBBF32YE2DKgIUsTS6+LAD17+ZJQcyOmIrtpcCmzUOOKi7iezCdhfzKCK2/EAWQXr
# DATA jkErNB4xbgrGgmggMJ7LnCFQIKdRshw+5ThmjmPmOGaXyDHbcKTZaMqzgX18dSb+WSz8cxr4DmTmQGYOZOZAZg5k5kBmDmTmQGYO
# DATA ZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZg5k5kBmDmTmQGYOZOZAZtcGZFZp1oJG5awgs14v7JWfI5BZbsX5tByz
# DATA OuVJudav15v71Vbt7fo8gqwS1Tu9xZws+5SVtX7QbPDnKiBj6nONMpY/N5ueTzlcrZWHfrNcpH/VZ19/noN6Uc53e5VlUK9KcyEK
# DATA lYCiUK586jfKnu8DweZV/PLUh9u4eRI+rBGEjc7SNwX1BRya3wjAJfOqlWKr5vn1GiBofkAZ51eZ/FZrnfC6TrXeXk4rsyBqRUwH
# DATA Qgj0S432WktAZhSXDGRGkTIgM8GxZS2gVu01Khvnb33JqyrlRvaqqu9f4quqQmSTV1XqjUt8VVCxU9UsX+Kr6oyi06mqXnAGngoq
# DATA x12ahspJ72hB5WqVerXZzUPl5hFyS6FykR81ukEGlQu69ahZNVC5Tr0TdSyoXJXe26xfOlROdhcWZZlBD3NVnkF4enXK2C5NMf/s
# DATA Z+ahcG9F1JnHYWGR/lZbRn+D/7Oxf1Coi/9ThTwMN4O8lRrr3Jp6epYFOr9AYpv3unwWPJuqZHLhsLjFCtfXX7ab1IF1806v09lh
# DATA HrtrsVS1GgxnZdUae24hzvlp0SVah44x5xhzjjHnGHOOMecYc44x5xhzjjHnGHOOMecYcy8ZYw51IZ7SDH8SQoudKthtg53bvfOZ
# DATA mZOM012uJ9JL8fllXP3IavnS8HfvmGYf97Z/wI+qhrvzmeLSaeUiiKHKmS9GHI25qxbj8vbn8uruTNaed+2Afiy4O1zKEHjMpZMl
# DATA Hfveor/zYz+44QeIjg7tjgTQntF8EYVqYsZys6xAO4qibgrenX4GkDyRIUiN9lIvOpAOZCyn8kTsiy7xCcZccpDROMW4q836CV4s
# DATA WSWLT9s8odspyeLD9nZY2C/EVAjhDWVo7+/8eDumplF+rV6+5e8Uytj0xa0e60+7w90728M7u36tVn7tw633qUryEUsOFRmkDB/O
# DATA p94goTnr8Ga9vPOjSm2HZmBd1rParhQ+3Crjbn5MPzP8Ed24eNPtrOZIlqMGbKcca1V14Dza5fhtI/WMGvyPL/4JGZvexpUbu8sK
# DATA czt+NV+Ir/nBrbLOTQ719uc7pU+SeETPMrhQIq0+3ljyyl48itO+EkX1A12YOC0rDhcBIP50BJUJwQHgeYYebs9VmKKuFTt2taDG
# DATA w/XIZMsORfI2FziVRFHPKuj519aZjNzy0HiycD7DOEjGkDp0rJUztLiFDlmzFXWlM/MuClyfhy5Nn6KfseIoYT/SYeqHaMBFWAbT
# DATA qA+iOaUIpxSxXinCOqbo9CKcXsSp9SJW6pReio7Eg9k0awC8a0tresrIbkQlrqOM0VXo2IuxIjLuE7Fi5pTrcSnTrdf3m87LXDBC
# DATA 7+XWLbVgroTrV+jRqwGXFemnOFnOPCQj7L2tRt6TlPRNMCZK2ZVMSb9WXialX7Wl9BuVsq2l7werpfQtgwbR54jTxIRmVVyt8nL6
# DATA uZutfLODWFDL55jdqZa1/bFaV7/G8awFJ99Z5zDrS8Jc0N7XBxgp3XwQ8Y4yioUZhJZDt8ovKmcyJhQmDZymfLlpx8d8JuTK6b1s
# DATA POOhUCYgd6zLcwVyMa99iHGTW7z91uzq5bxUDj56NNBOqJvIvTn/U4b3zMplJR1BejKFCXh+kQjvwr8nUjfKWNGWvK2cYTRmujSh
# DATA s+z+XCfPZhCEP3K3KAFeqsKsPQPJGdbTYLgBizloBsEqDZq86IxNBVvkfy3nhEkG5uYPGAn1CgX7tvQQZEPATuQbPP/iFnkLw81L
# DATA 3LzkhHlJzv50UxM3NTl5xvFMJe4wxqOC60ggcwaZyt2bZiIiwAPWfDJtjUovTFnkCoJTrDlmRKgKopw2DMVxaYTQtFjD/ORiDr2A
# DATA bTY29lt4tLYBJnzND0R4LhLCLFylaN+UGKrQqZnSMKOLsif9dIZo7vFvs/SQxtwRM70ogdJZFBSESKZHeqBlID13F+kTHei4n0yT
# DATA vUk45qF6HMGQVvK+8YSlxySJ+WFvGjJW+b1kIsq6aqybh5sKItmy/CS1Yo5YODTuyNC3HSgMMrYJqo5NfPdYnToAihz6cHeFnyZY
# DATA iX5o40XhIQdhgKXW4NtbF/u4y1bd2sjPG4+SAoMUEIhwagjCUPGfGtBzhwXhFP5CaxJnynrCss1r76liaaPLFj6B1WuHUn/XpOku
# DATA dtiPEpBb55MlZkKeG7ugqmgqMpmFD+DeV29GvpLZ1gfBVyEbJAv4BwB7EXmsJXdYtg1GTQGVaCRJAfMO3ttklqr8UAHHlA9395O4
# DATA y5LUrNIGgIJkKQ1QCRNjh5BaG/NJN96dsnxKz7H+a6GJKAe4TMp0nLGgnhOuTnoyC4MO3XCYdKVxo/D4sikrTx+eS3o9+NR12WkN
# DATA aynDgjeetclCsZ5j/TluhGEXFpA34ToslZXGLoYX8ys9kNhp0CFLO6U2uS6Jj4AGV3CvKQYRK4kglMkLqWeIoe1F3R2ldUzP92aD
# DATA waHiraiYshsn5Yoq6R7mSIWsLCh9wkE/UeqI1EFiJygV8aSPdigFhj5+HlErhumLZ087WpizpTdWg3am8wttOp+WFfaM1aHtPf/r
# DATA YWGPMRJo2CUbVVLf19PCro+a9HMhqXoSQSLb969ZXhcJFcsrZF80U2xecXwpUky531jNG4XKu9DICJIakYpZkwxsd2g01p3YnfdZ
# DATA u0S4YjRVYX1imTTR++h33PNmnFnO6D0gmT2CXS40Mqo32b0yM4FNK7vTE1h4MaTIDtVNN5PBquYp9jLsXFRfnlqEyxyMazEhcMUa
# DATA kvOC/jgsMJYhHk9Qo9PINDNRcA7NdFW22ZBhP8RdZOfmvK1kc0O02NZCZ0ubp5CSUzMWJdcG7sI624Kt96JZeRnW7CBqK/Frm2r2
# DATA vx19ffSvxeO/PfqeKWPfHH139Humi9Gn4785/uLoK5swdvwlriwCzv5vXD76HT38NSPKvvboy1d08Ru6/B3IZEe/8/iePzDj7B/k
# DATA vuPfKpDZVyCp0Qu+pH9/q0BmHJ+vEKfjvwMDjXlnvz/6nn6g+//o2GbPiy0rjRwNT4uv85KVIW9iHYjmcKIuzpO3hIKbotUjjtTK
# DATA fwqVRWbIi/co2WcvTzjJvEoWCRHNYy3K7O35aDicmW3TZh3FVdPMlhTM5RHNxKeSLrxcXZ+/XXYQmLsfRimNQB0ZsLmQLhhtJu4l
# DATA 0fOHa0UW/pha4MBmGxXehXPN7nqW3nk2MzA1gBeNIaQzGzCFo32Iv3GaQrnnQD2RCIqdc+/BT+l+0TQvaE6F3u9iICZs/+wDXuzR
# DATA xcECz2zDmrnaxllsds+KbrZhUhznzFkDZ7UGNNbsbEbAS+HUukID4DLG/42G/9ON/lc4+Ev9XMgJC3X2TFrQZZDNFhLJdDPKqnQx
# DATA WmCcybKyR9UTNfWWgJ4K3tuPHz94VFAHS9XKMJcM7xmdkP3AKzucDIzQcEpkNKWJKkvtedB5qsfcTfFmpip4lNdQBssbAEhZ3AHm
# DATA LDMC8oCz8STqwjeSNwpsY6DAzRSdhQcDY9RR5gFbBeBQiXkoyCmOf0qvyehm7FRJD1M+SqnuaTu+meObOb7ZpfLNNhtrNpr4nMpA
# DATA vlqL/ywG/4XZ+w575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBnDnvmsGcOe+awZw575rBn
# DATA DnvmsGfXB3vWqrXq9bNiz6q9Rq/9HGHPFtafN0KfceaqzGNKmNC2apXcYTG/XsnnelVYTpLtzVzGdZtREPXm8E3VZhAIqmse31ST
# DATA LLbiIe+WeAj7KotHdf7QWiWLRm0eW7eMF1a3eGF+q2kYVDlC2l/Wuk2/UV2sOc0aVZ1mX+qclbyw3m51wqX8tHXJqwgp7ZKSV7Fo
# DATA Xhsnjx66sORVhfF1ScmrqqdPlTx66FzJq1Yq16KRVKvNy2sk1bp/jkZSbZbP3Ujs5F14I8kl79SNBMk7byOxk3fhjSSXvFM3EiTv
# DATA vI0k8JvXopEE1drlNRKKxTkaSdCon7uR2Mm78EaSS96pGwmSd95GYifvwhtJLnmnbiRI3tkaiQ1sLTe9WhDs1+r9aqu2X6zVh0W/
# DATA Vfdq9f3qSQDV1Y3gLDRMtnQNDZONZouGWW3XK83gLDTMchT2fIuGWa1HzZqhYbY7nW63Y9Ew/UB+vlwaptrMK7M7y9mjlt0MH5Mn
# DATA 7GSi2061Fq+xL9k2kQsV89fFe+a3KiwumTV5yazUxFYZWTTLhaoWzNeGXOfVs/xjeha4fLNhdjfNJvcm4TC3RndSctUzS5bnF2/Q
# DATA K/ULeb54d+ZFXLVDUl7kSxGJK2AhECw1LKI+VbXLLxe0Wi14YE4H72SP0ZJUsdtwwfe8uF1oJffT0TodrdPROh2t09E6Ha3T0Tod
# DATA rdPROh2t09E6Ha3T0TovgNa5iObci9sKoIjVOZieCo6pGVR05aZfrjWDRv12bs6iHuPDw3hMIw7JMJ+NceWGjycrtduKjXlfHWOH
# DATA fsBo2h8cGs4VIxIpJlSv3sT+/u0KYxHfil8XpOK7OGcup5THg1nqQbDZUy/iZ1WUVj1/16sEPzJvy4R2ZF5KebAfMapzm+LwY6zx
# DATA 7ywLyWYZWudMnSCME4TJCcIsHjp26jBOHebs6jArlZQvUzVGd9aQg5D2guJiJQdstOGdN5aEzPXRMbsKoKEMlQz6kIGMVTj46gkg
# DATA Qf1krptPc8g2uBGWggR9iyPIN5X1nQYnuJomaIZzsATVZ4TNgiVjDIo6Cd72X8evnwREtIIzSbGvmdQEJ6elcopkiLWBHgBeUTEJ
# DATA tt87Ob76ORNZc8GK6WaZvmFMtR3E7RRCiZAcyewW6rrGcXRSdckCycCT2SUT9cZJMa+vifVKyJ/pAvSUicdDVcjPPfRvGenPWIiR
# DATA 6f3QM1EdE5YHN4+ukdeBbcBFGg55DsDLMywIo+aaHZpUsVo0Q02wN5KmNwXvoE+Vj4zDyV5khaZyt9ejvrY9m8C3gedocjWJoNAU
# DATA T7XAj/JXy8wjZVluVmKiKnUoBjLrYNr1rOTdS4bsFqOur6DEekZdo/+UiS6pyVxXnggnShcps2UyyOyQ4jWbsG9ViQ9tQA180ZRi
# DATA HPPETQRWTASczf9S2PynJZ1cF6VIe6fEeuTJWzGPmKKWyOvREIkbsWoPta1htJZ98uzkJZ8vdbWT1KXn9nhcBvhkUUDzouEny3RI
# DATA lwJQcmWnt8RIRV4G+HsT9rw2EZbewaqea+94XUxrY2icUu5bkf8YVxmz4CBAIqLxGU6lzJW5uQkO81E27dZ4xbcfv/duwbv36FFB
# DATA jcPSXnhYUFrugFjKvEiEFsdQCQ21kiorNVIpGNnPOM3mDRpsxw08nmLYXkNUfCSdgWx4Ww+LvGtFQlVinaK7UAIdKXlUjh0niBLW
# DATA jUDzi0YdKIKOIoqf0mMtUO2l6trXy2wiz5pXZV2L5sx3ICdEXQvOijWto61gimxwqwOGkfgzBEYKs1+079mAnhwqSUwVy5L3QHNq
# DATA EHNeHdMdWej1wngwm6yjWT6UYLBwtYpn+RJZ4HZ/7WxwZ4MvtcFVJXGeeOeJz1l3K43366PfznUaI3WGcw498RQaD7z4auIUG/cS
# DATA HiTz4uPahT5PP5uNgRMseT/DHvFDg2ihO7qzDkRkhhiLjbSx8bcz0ZjtnY2F3DPdAmme+HrnVW34PcIxb27Y0K9IFQBbZhyqL3j1
# DATA prESp9J7Tyf4KMLceFVHnPVkb0wSGoOpYfeX3vBTGdN7oDavuOUDmGxIpWhxs9g0br2Jd97U75fBaD4aylBVBpyxePhN3TtvqM2J
# DATA XIMLHoaVHvX9CZUZYz+pqk27fKcaIwqeDMYFLbUNzh0wxWlfwu2qaK2Ix3vhiOpU17YFTWTuZhL4c79LFGzTzdhfVKKTCOLdvHig
# DATA La+TI/KzeDKdQVGdpcStOKgCZjOPaytLynOfMkkGJjI/GbOiirmBKnk0ZZX0MQ+elEGDga7qqRWfm6qgbqpKt4JLvx77/UjbeVne
# DATA i8kXdoc06OtZTsb20UriitSe9pPZoMvtUszZESw/bDzH1ErU1aWASx7bl2QBD5LDIQdB9jl41iHE4S0ZerDoP0naPHAqifnZiFmI
# DATA KqR1QPBRcqD0yrXpHE77OvofTFjOnuq9x+Im4uzm9RbtN2anM1njFEyovc3opaiz43vwAzNSMxsXSChAFvXtPDECqX4EBzsN59FI
# DATA 39tVrMdsbXBdYt4TV7RKTyji+fCrG/e+8qwjYno9I+Mq9KPBWPVnsuBp9UUsg08DZZKDKoyj8AlKWHpM1D2sWXajIV5gz7AUWIFC
# DATA kfkgY+HRCuypmbJjbPC5Wf9E/YyHGzLEXyzb/vPPP/r8w9HWK3/xov9HWR8NPkaHEY9mgKqODy/8HVi7rNdqf6HWjef+9ctBUPmL
# DATA cvbfX5R9v1Gu/4VXvooMmKHN0ev/4uX874c//OHDmRAiOtSBxF0eZ1AptlLei1xk7EdWQbx7775DvQYvc1L7TgZdXsKnB0oU1isi
# DATA lUK27R4fttHfPyH7UH9O0ld49EKnP4jbnrr8gL7qWybmwXTWVv4ZfQVHsjAc6O8zMl1eeeWDh3cfPLj/EBuot7a2XuEzNq+oDZY9
# DATA 2VfNzqZtmkx2o1u9dGuHdzPiZMgWGHw3qVe8Carvzc4gphnM1u1XZKt1Ly0hH+Dme3Q46mzjoYK3RfP15pa1A3WLnUJFhF7Mcmtr
# DATA Z0f7l0rR03i67e/cfmV+32c+anyO7GP1EL2BeseDEb85CyjqILcK3s9VZJa/+6PCK57nfTaVUyS3fN7uUBiGT1+f9bD30a9Xm7XC
# DATA E7IyH8V7o3Bwa+vRO2/99TvvvrtVSKfdOLn18y26TsPDVmFrHI/xj/r+0ec7KnvUxtRoMqGh55e/1BtVUw7QvsCL5bLxdXWWyB7i
# DATA 3dxpLf18F2PBNFHHKlT+62jwg69xQR3yS3AwCq//gRweKsXpo7AXvUN20R4OKeD2EvLrHlayd3Dn3DXvVa+87PIdPm2zNA36iorr
# DATA AQyZbRXf+TfS/dmprfmgvM9fQSV+5RWaQsNN+THTjbbjUTqmUfhjKXSe/O/cQhEjC3gFHZdgA/CHElsTKaZQ21vFrR38MIhG2/Ig
# DATA JSTwK7iGJydRCfsJeBvx9mTr53eL/0tY/EW52Pq4dPPW/1T86MZW/oX4bxJiKvczJOw+in97653RPk77WD0JP7O1w8+ogXiXW3ou
# DATA MTs6EXILV5ZtqvnTj3FSl2Ja837sYUOv+md9HDhcL3raIVs3lYmkigHszUkXvQH6oxLvfthW70TV+Rj7q7d3dnJ5mlJMp+Gog6rI
# DATA jxc8nB4w2amu7lC18/yNckdNdRXGNJqo2OnruzqePy9/JD/oG7HnW27iQ4lb73SpWLbU49FoP54ko6HaG27fR9O5XrxH9372+Y5c
# DATA uT/alyNBdlLnK0FY7FEN+Oizeu1zutnEYkdXGitrrJfPZY/1y45qPOfJJJyGlgMu/BWTdek04pGdA9krFouR7y/g6C1HcovsPDwt
# DATA wfCFyfyFp+Xy3KXdLbVnRa5l71uerJ+O0tkYwxXNLqxoqkThPz7t+TGlTHoK3jG4Ta8peP7OfGKWt9aPP7Ka7Uc/pidxavWkmOkM
# DATA t6sPPWfFjLO8RMNjNOqqA6imvc6G2yhk3FKiyQZ1b3zOD2WPdQjKHn4aJV8J6hs03/tWNJY14b/E2hIcG95QcbzeSDpPcLoG/1Dl
# DATA owcnhzx9Ksh8ucP1EScZUHDolAWmR6Z/SQWJHVjU9ypaHmwZzGmZ3qcWiW4L/QwuKT3zhw+aJUMxXUz7IfZfSXM1vd8uRXYU8UVx
# DATA ZCnTpfQ4gu0STg7fYGHBZHLIwnbx090tevEo7MxwoNyM5Oi8aara1TdnGUil9rGyYrhXNbfseDe9LbummUe0zzxBd5KkJRDCtnU4
# DATA BVz5yccfPPzJ++/+Z++X8u3ew/t3H+sv9//ne+8WvHICpIcJk1NHP/e6HFr2CuqeDiTy1NyicJivjXJNDZRoh6VPqOC2VZW5wU0z
# DATA e8nUTjhntOKp7VpWYokKbPvnudvw31aXawm6S3kKn4ri3sVHk+ulLNd3cdgL1mUJf9VoQOpHTwuLQReLqkpw6Lq/uoWnzTd+mzGn
# DATA 5eU0zS52J8l49y4srmXhpnqJhuzT3VFC7zkoYuYbAySTSihUckWU3Bb3aKYgd5YGiFhSFcGT2ubVoehWg+8wU/SAj5/xRRnY+WA/
# DATA KsBZMJ1Noo9lC+Xu48lMHbzWH8X63K2WC7Juytd38gVptRhVqNqIgp9qvJ2/fbPhSoc51wOubKGbdZNsiXkx+8Smdi8p9oWy6Ofr
# DATA o1X92CiTTA+n07DTt+P60WKpLftv0zz312a6OpmXN7A3z+8Pu5/5hUAsA7ahYXeOptvqm7KTb50ib61JpkRqIXtZDiB7ifm1hy0f
# DATA g7nugaJtMnYxGmuKaDKU8qFhrBPli8eTbNq1nn7j/s/e/+m7755YcvQkzZKWPZmVV6CL600IOOyoGQBGom1VjXlShJ5bz7BLdyd7
# DATA 7NV/wL+oopPbcJbv41D9TnOAojK6KU1674VVMVY9wyb80ifoNthi6kH+B4+mKhK5DpvPbWxnkxncV1LxKXjyjScYypp9Cgynd5//
# DATA gRCrCegv1Yh/843XPZ52powGVV2t7bAueT/BoB16jO7xsHtpBC9lx6PxKRyTUTNniDxi5/59zMK23k+wjzurkR3jQ2/z9V48GUbd
# DATA LZQRVbSPP4Y58DHZb7ve1scfo8Q+/nhLIi3Fd01diROcYh9Gl+H228z/V6mVa4E/5/+DV9D5/67iv7/8wc1ZOrnZjkc3yXTwxofT
# DATA fjKqvvLDH/6QhTuEV4vFF1kYwxoDVnyxXJGMIw291Ru4HmozyuPZ1mBA3cIaryCWKeo1/Q17mvTnfpjCN6i/xtAHm1hOwLP7E2UF
# DATA 0Xztz6bxwHzjOYT5lg7WeCHDie2EnHdKTvsTIeCZC9TIch5LjvJsMqAYS8+p403XePJHHQsvnngye59JXsuQmY2ealigTL5rd3Aw
# DATA qWnO47UPuVxMabCljmWUSfRJpNb/kCEy60y5sPR7fzrem4Td6GdQO9AvXoyLGZcob2S4wi6ybZobpZm7SLrXJQnRt6lHWbsH5aif
# DATA kxHf8tbwLIfvsDw2PPPErtAt3kW1taPDk5nFmH2latqPXT67Mn2Rd0xxGmaqJ1ActJ7eyk+lOP04PRxik8y2ZUxyMreO/s+jr72j
# DATA Pxx9dfTvR98c/+r4H49+R5+/Pvqzd/w39OGPR3/yjv/u6OvjL+jaH7zjXx19c/RnuuX7oz/R7fjhV0ffHn95/F/pJ376T/h6y8Pk
# DATA Aea8xECNiSo6ctixNIQlvy1fUmX48ST248Q293i9dFc7SXqrHCER2RuSz93ZcJzq36IRFjc/DtNOHItRgn1mGGB3K3qGJo6YboFn
# DATA xCzppGa5wyfoM8ZmalvK5rZkT1Dsd3MpWmI0YErZ6VORbSN8FN3KOSduoLkmopyvDFirP8CUcpenkxvNRZFpO8t+7g1mUJvJ/YQ4
# DATA YCvytr6H0j5KtBtR3TGJGDamhamkWG2/Dt3D+fcDMiBoFpaPnJnWf9zrWrP2XPapqfvDN+yp+xvvPLx/7/FPHv7nfJQXptK5dNhv
# DATA yz+31M5WzzIKfsmzC89IYtHQSlxfU86UuWka3TEbcZPjH1V7lvVj5YQyrm94oJTqGtxM1RVO7e3XbmUOso9y34offVYu1P3Prd93
# DATA XvuwtHNDXfjos0qhXsVcx3611Qv896NvqbX/D2rTv0Z/8G/UwP9/9t69ua3ryhPtv/kpjp2kD0AB4EO0rECG3ZRE22xLFK9I2Uko
# DATA NAokQBIRCCA4gCQ2jS4/Jt3pG1dyk0rdmuqq7p7UvR9AUay24tjOV5C+wv0kd6/Xfh8AlB89NdPpGYs4Z5/9XHvttdfjt75QO/7L
# DATA 5NkfcOM/+4viAF+pl1+pgrD5H5XUM/XkA/XsUfLsKZT4WP39VKuqkfORMrALkCcFmQR1GGmvxwacFrJZQS1mTSVf2zz9JFe8l4JX
# DATA aFZdWgJWw/OqK4CdvdQcdJZUW2k9Ps/LrywH0/B/PfsUOJ1iao+A1yn+R8NTI1VzghxSjf8pvAP+9wucjC9gvtTPZ18++1JxwCda
# DATA nw0J7zNfI1pKHZ31SvJajfXMWLwIv1dnrQ/05imszlNoGNp/DN18NG/3DUcn1v/8188/Ai6uF4/1AJaWGjUspKXGjto6vBHi8OC/
# DATA wQVcjZNeMBE4Vh29ht7ucarcu1yt29XJbJ3SJd3Wx8aW8oUX8k/W9V3wfPwtufd3S/ULxYLajEtm71Ua/1BWTxeLS2+krNANVOBU
# DATA Ibjq9QC46QgVxmp2z9IKXN4rlXRCXr7mFX6yt1oXSlKzVpwxdH+8VWdrE/FgdEfZ0E6C38Fmfv6bZ1+UDAeQ3Y47/5Eq/AgqUsUU
# DATA Z3j2GHgA8wdVucz1n59/oijsKyBPoFz1+9fWrBJYYWwn01hX6rCTZdz2FMKXnR4T6vRJmLEXcEL+rLaWWvIEB/UZyzaqx88/UUKN
# DATA 3WNWNrExAdALbW5Hb2NsjoZ1Pk53rq2vl3X6cHkowHVJzTeDE2Np+IU2K1UENiMSJq8AfKUZLNCyIkt4jiYOVQz/rdVCDn0oL7lw
# DATA Fh5Kv6dhPP84smpfPv9YzQmSMRxLnyJtfUL7Nn5+4el0xXmnyFhN2BOaSKg6INnnnyRUAh5qSuDlxm7HVlvdRAuj/r12z13ffCO1
# DATA Yhd3K9N/K65gV+lL8NTzj4Gzq5Gtb2+WzWacgyB4RIV0fXu7sX3r9m7t4vLK8t3e7Y2bW+vvrb+70dhe39q40bhz+0aNU9WgMPyg
# DATA eb9dvQjYDr3U2YWp+VJ1prF7652NLTRI4CBI8t7c2t24vbV+o/G37+02djau3d7YxSJ8x61g0cZx+2HhIgjrbv13e7u37+zsNrZv
# DATA 3/rRj2srd3s312//5Or6VuPGxlvr137cuLG59U5jY2v96o2N6zXEk0VjDK0WXFR9KSy2QqiPZy0xXGcYvlYENDy8QS3IUoX6demV
# DATA Vy6+EizRvxPvNMyGSPP5L4nCFAWruuAlfe8uimlAek9Ov6iym2cULBHuaWICYXF1ijSoKAoORNVlEBI+V4Tzper3E+A5Xzz/NQuD
# DATA /OaR6FMigh/31zLjFYwVvuqKGmeT0CCuC09zA8DV2Ks78jmYt+OmbTRTH2gIumnGatO9PfVVHQHr8Ltcli+uqw02qBUs+9mg3R5m
# DATA 6o5zvz0cdtQVPk2N6oOQIlHTIdbZPngPdw4oeAAxKrRfrPDQZL8NTsKk9EAhBVS+NX/WwLE1nLktaucmWMq0QEoVwImsvkndGw/3
# DATA GzVo+sdLYdng5PoMmaw6lxTlKJ7zhEj+N89+h5wVHgGvBVb8KWge1FZQAghUWpbSz3/lsGrnOMZFoD7gU56/LJwHHvFOewRm8iwy
# DATA GRnRElMibyapMDyXExQav0S55k/QOZAevEPlSx4Q/KN+s60fxEzYR2rDK/lCHXDwkaoOTiuYsCdmSeLzzq4b+X2bZ+b5KPhc9eVX
# DATA dG5wJ4Jh0QnsLwCL4tKJIlDOSnBR64GCqwPIurqg4mPBJV4TdU0rEAtxvrGXXl/fXb+6vrMBp1FaL1bkW9vwUninfYoqulISKBu9
# DATA 9rQFlVdcXkUPWrVWQKZ/xpUD1o3M8AkJICCjwUMjS9OCKslSsc7PEqfjRrbifsif+rqsLx54i7QYJPASWH/kKc42hSfatwpXxNsF
# DATA +JiroCcQbNO2d8NtchlR5ToZTggo4zzPBbIrGcOzGJTBmtbOb2tLDc/avjAWUigpaRqt9zCqglV+/j1brHQIrTMwouL05u6Y3CGh
# DATA gbDbQYgfNfv4pywNBVnBE+yw9J56tk4fycFU9LSW+BlpLSexxsCACaq4gj9t6LeVFitdumLD/U/64x5abGugfpNThdU/TAUgVVnD
# DATA Uc9xMOnm9jpVABfRt7r9/WZ3c/v+JXno9VoNTtOw+lxmjKV7/Vi6FE48UzjAkXPQLisZIfFAsYjTIeRl65HxAgNFKuOeEroLi1IR
# DATA mQLAjwuONN4/qB/G4jbv4ppQkZCvDDK7OH5YIZP8kBRj6p7wOerIn0aPB3xBp8AVkaMeI4v9BK93NodISD/xxNKqWQeCs+1lRmKH
# DATA BM/Ai5/Q0EE1Fb8B+TXvdMjhbtY5IN2yOS13+4UZrdtZVY4K6Gl7AndB6+CqJM9+RyfvY+z6L/DFn3isn/Gq/glXAu8v1+CGoce1
# DATA tbH73q3b73jyUmyKJSVHn8fLvzN0oCxw8SL4x5LgeEAidMM+8TzBnoXiDI+roCUjs4T2EYi6KgZfkICe+xH6wFYXAs+gs4nDvbVW
# DATA MCJqh56rWJpYX8gHeO1/m+A9nK6nT7Sx1nbvdFQ2+haFktQHeOd9mryz8ePau+s37myInkQ98Lxx8Cagc1zblwLSV0KcPObQhYtB
# DATA 1KFI1TBlGNGef4k2tU9R2PqKtBIf4kXdulyxbpa0OXDx+lM6x6UE3VllNMTuHNcw975iejp1gr1rqvrz/+RrH2pLaWqt9cKn3gDU
# DATA 1z/XF2/xmlc9s+2kEjdh7KcLU32fHQ9tvny77uvWTRaEXJjGz5DF/ZPoiAI+RvwYxvQVDV0N6teRW63ZtmApa2THzdVXLtmjaXWO
# DATA IGKxJl4AFS5SNJ60lhkYLWHpcD9u2oNNdnA87t2DTYZidLd5st9qVsWih/kWrNiCYinZT319OvWoQnHIBazPGRe/P24/pL+0rYai
# DATA TRswEHWkGu9cvrz3+6PQc5etZl1KSEIsb0ByK+pswXEZRgLmXzyjB2Chhg/UTzjBBsaSuPP2upq5nTs3dwzXBS3jwDFqzxEFQho0
# DATA qrloOoPdnEsBgkRjbOJoPUFCf0x7lAhKbQR9WJMpFoa7ZI8DIh7IT9ghn+KFNEnSC9TDC+jU7/VS1uQ+Ig40aGnMvJfoFOmBbTul
# DATA CLjZy4RO4CJI6fvFsP8ARcGg77bTQpHUJujsbEvduaYStQ7N8iH6txaTpOCtThFc9PoP8g0lYgZAMR66HZVocldOmNRXlgyDxwWr
# DATA jZ//HE6QjxXX+sJit5h4sYYzuBSzQ6AVOEaK8oLJWj0NmAUQuNg5omP5F7+XLKFRL0HRP40K89Qr1uhwGlHAlrEJV2BgK3XeG4/w
# DATA CsVaV8DLgj2BR23/obhzZ/oJyzZOQS2taJJFtRNRrS11UD+wi6kowNDDQ4ysXacSdD4AlZa/o+/07vUgIl9Du/IXqRdAxON+reaT
# DATA mEVeqGqXxXBXAB7JCtBZ7itNcNLkpKP9Fc5jMT49ODKOw4dP8G5oDSV/+FsIaQKvuAM0D6m73HI+pJIAvgz5IYaFDjHMDnJvQGTA
# DATA mBmsaE+WF1Hk0nqxGK/SGq5HIUVzX4t+iUeBKAqgB3t2WAhPG9DZYUf1bIhuulx1nSI8oVVk++KuYQLkuEs8Bu6WsxL6mzyqnPKt
# DATA xRJ7nUMSCayJmOdLfzZAx7HHmUJSMsRh6hm8hFAje5RYhEZP5XEM7VZad7irfEB0BMSBqqDbfcoR6MsQ7rAxVhdJoDzkDzzanW9D
# DATA /b98oDJL/m+Kc/1RCcXqqvz8Hw0XI1WlYuZ4V1bSmbqOgmga8HHkgZpDkujsXrEGzinomkCY2+NB6QaK2Sy9uZ/1u5AzzZog/lLX
# DATA uwQPFuY6JJRE3u/ex2xAWWPY7jZHnfvtxqhvx0KBIOCURZNqGE7liPRlLa1Mked/yQKx8fcjIf4xWFhxZlGRAdZ7vIw/+yOcO3Rr
# DATA eYTz/dgyI8pgZdMgswqPw9kdxqPr16pudVvHO/6HwE7zO+yK6e5cLTAF9Nrj0bAJYBFECaKRUHKtxosBpCCYf2ObAcTAox6E8VKu
# DATA pG7ztD3MEsjWmjQPR4BV3u9hklh0C73CgCwUaE6IKrohbamJOdgY/iYnpnxXOW2edO2j1Lyg5xT6Uc79Lve9el0Pidig5ywlWq/u
# DATA b4TcJY64mkb1q9yauy+thTDXQIuyUJeIKzSj9sBDkFcfwz1UR70QbcWfLrsx2jgucx+FDXeWCkJSWk3OJkYTIjaHWzvTTA5uL9AZ
# DATA 1Z9Zfp0r2T5CifYp7k6QarUru+j8UNqAbfJzdhT5AtQMj7WRhw0Uj3P4LVna6Pr+KercSG2JvPiJo4hwPWHMYsXsogxMJDsvuEey
# DATA VBa/oliHJ5WbdnIuODcHPt9iRzh2Mvlewsi1hL3EYEKdXhmdXfX0Mn6Xus/fJ6CkfrelkZmQnBb8M3WWz3X0kgJCPaod/hsolJ9/
# DATA JB0oB3dLirAXeUJaZY9ps395RrGQTF5E3NxL9ZyDPc1wTh4VteaUAlkTZEPTmOsVYZAFtDyC/hEXL84/G86xkz8XomqweKnIRF4P
# DATA TNPaaT6X/ZDkBI9tsckoCR3lWihpVeeIQBQy1uI2+psgVIUj5uUrS2c4auROmfZSFrRpvbfclv1BSPmoNGO/jF97pQTeVKgleuPP
# DATA 13kuweEg57j5umupe47aDcyxpM4GxOpuFyQmwwrW7Bo8ATYhafWxrB2o/uE6ZFubzvAEO2RhrpQ0ADBB1DsTnBQolqOT+p0a8R/Q
# DATA 9EFGo0fippqE4tPjUBslST9d4tWbe45LAEZ2kpVWyAWC9HNvAvbuMN9GScd9HSceUwZnSrZ22OWoMmXbDN+6BkuHKSBSQnvwkzaB
# DATA aRNU9vjE1gnZM4ms1eqaa4yXgrNY5/w9Zp8fADFsqpk7VqKmqcfu5LBz0kQf6nwBy+oeF/duiFIJWxKn0+8LzDrgFzZ7yZiVM3Lc
# DATA ItN1vQSEodt9pvw8/nK74VC0GemZPbj8ACkgOzdQif8xd6+XHBk5rnu+awULWTtEB/lfRP87tyHSTZv2RQu+dev6RmNnd313Q8fD
# DATA bG7s4I5lJooQQHDCcmfMuFDJnsdcZywP5WZy0/2mRksccD4xhyI9OPZpbaPyzZdWWBiHy5x0MgCkdoPASNWXxQ2M/L2+kHh8g2OV
# DATA YCI9ewz3SoBfdPCdbQcJp47U+tHB13AG/jpZ7r/66qvmRqxn2Q4Cv90mpAhGB27f7/THWbJ5c/2tjVIyzij5AfgDPmhbKaF7I9b9
# DATA qc0yAMRLq0ZCs0t+Nu6PmslPFUnAwY4L+QBjv4dtNbXjNkaYdxCZCDJ0tfgWi2EZ44EJKefYQ2IBJW/noTth3d2jcj9zS9raQXcy
# DATA 8SY9/w1QDlL8Si0m9yxvgbBcKbizaR/abrPXIPBI0Cs3WJov0NBKNMsQ139w3MFU75YrJ+OKMENo1YCkRXHAPywVZYOqxBe2WoFu
# DATA DyafhHhQ6QhXtQ2BCixW86ADWGy4pg+aw5bRJ4DtN18lTGp1DDbh4UwrFwgev0UXDFvh82eyjlKk2CMx8iYopT1Rl8+PyTPG0xKh
# DATA n4hRj/8qx6fQs/jyZAvalQMTF0ODU3yYEjoDE87eB+ir9+9+PwL/ZnvPO84lpFqEfj199hlZsUEJpSRqNCR9HJkKvrDAxRsjSGJD
# DATA u09xyJjTXS8VP8wdPb93xx/zUr9QeKN6t0J/Fs9WShTsR1/PM2hx/yRnpA/RfBEfKpmZwvEJbTXMQF1yC8YafMH+hu4REU6K/90L
# DATA zo5fTXFegyKZeeyZcp1+I9I345Og0xoZ8NljJlE8V0m7BfBoUPf4QQGBvxy39Io6kiAOam+5niwma8W96ponpkHFwazAnqA3U8f3
# DATA e/aKgGv2IyRhXm6ON9IjA73Rp6RN4oGD78c0C+QV0tsDp/gPzTEUSf2cNpPjhfwpK/afUvw5aXyFsgzec+ZuH/sNF1ZHYMP7wCXD
# DATA yDeSSccvys/X7S9KQQvGmuTTqVXI8lnB/AJ2D5mTOXUy/pB657p29k79VthZcsoOMEHBrs0dIPaMP4R21XS64bWPhj81NU4hfXP1
# DATA P/U3rj9zZlLOMUi7r8FS+FX5CJi0oNZizN8Wf6vdjmAa5JmeAatQOCTLDzmg0lhL5/BLcbwbKFb7H1GH+CHFZnr8KTDgPNHxhD7n
# DATA ovwJ0F9MwuFsP3iyQ+IVwBG7m8d5SbZvlsTIaU3JRFRQC2jo3W00qZ2ezJa/W+x3ulL1XPcyZ5aD+fw3NT80Bdr79c8YWPiHIJLj
# DATA K2RJH+N/P3r2mGWc887lYIBeFXuU0IR902s103N03Ats3kwRTiQ70B9VaMiPf2vCtigul9r4m2Bu/oca0h8wuPLR8189/2dm3jI/
# DATA EtIQ1br9heJaVAUsNYDr9EdIsR+rmp6EYtTnOuaF8VxqOVFj7GK/vc0BgxaALAsKF1dF/0xVodp5bfmHl2RWDo6JbrAd8q8ju9td
# DATA RE+7i14rCJlaD2flt86Ic4giqs1+iicfOiPiA2sMeXp7drGYopzXuu/cSxR7RzpxdVHXjXoUloCUkai5X7U5H7ukzdBZ/qsVpeuL
# DATA 2DIvXzKdfRDoMQPWJapMrdsS9H8eOz13ho8dKwW3o6y9AU6+24gYWSxq6z/KZyCKgdN0BTCO7rVPs8LeItfDTdTtTyrthyNQBc9n
# DATA XxZfPlv97lkv9EUaaq8G7mZzG9fnODhC1XE80E73VPTeZ2QaQTdUsv6BRxgp86sRX7eg89pDWVg+pHPHiXDsz2lF8YHUzI2kY6Kw
# DATA G/+SDRRKfxVjZ4t2NXL9a82+oNL0qSCREs60O6vir0xyOhYnpeUUD3wasXG7nwvg+TyWH1xQDaiba+NFrJboIk9xgdGdxVWyrb62
# DATA g4vxjKHBOitptDm2p1ac8t3dR40Wv92dYHaAkqEgqMX4gOfNl+Nx9m3tC8U/2BUT8OUqrXZ7AH+wosryFDQCFZzsaUm4PEeLg3b4
# DATA pVrwMM8VJ8c/4NfiJP8lmtXgcEdkigRipdSc/RGccTBc1ISIP/9YjnYbI8ESBiNOMHGpTTZ/TWZlz2zwOo7dgFbEtxYXD4Ji3AAU
# DATA W1T5Qpsl8k57R9zOo5X24WEbFYSq8wXRHM5iV/OMSFc8bUz5+h748ScZD8p52oc1d/XN3eJR3nARmBrWVnePBkjPnTjrMASJCgUx
# DATA SE69MNZCJHrfZehc3EMEcKaTilDvOn1jtanwWoBRs02htKlNwGVIN5jGg01rNbyi5DLvc1w7UEXyBUWkALGZaCeOVOOQmxiohwUV
# DATA HO47YVgufUV9qYZtRf8dEECBeL0V5QwZElHKi/E3uBh7y/XKUKMV4ZPyisYvqkoZezmsthANSf0aHQ0JLFz+/hlDnrc6+FitKQD+
# DATA A+63klEeoqNcs9XCJ0ogax927qVR6+Szf8/dubDZf6GoHwTTf8JYLbU+n1MUqGioEtpBT2Gj4BbBADQoh2BaH6AH5a/sO9PH1sLw
# DATA OuzxBEIkF/7lF6gM+oNCuj/udCFZBhoRLJvP7nEnYxYCOCFgQugjXB24OGECAO3iAa+Hg36XTNxwYoqsYNU3hJyn7R7QB4EPsw0K
# DATA cgf0VI8AcbMLwTuqwh4mN9DxYwBJrA7ESjhCG8Yfxnm2uBgLePSlL5NkAs5Q67pU5cubBiVMQb+ffv/7EpusSdQ+ZWJc1z4/tLYD
# DATA OmWZpewuhhXjTb4e6zOn+1BlCebKroedTOkzN24WFeN0UljqcBILpHex7xbcgHpLTg47HYbKC+fKPXqjjCF/oqasZXhGOIX/Jzsh
# DATA 9Nrlzrk2OQ6RO0rJza2d3fWtaxuN3R9vb8CyAjdTOwQZGWHx9glQ/+C43Rp328N04msN6X+F/X6/O4P0mAuTJOzMp/DnWi3Jq0Lz
# DATA oGJOB6yZV/PBulFoSf2yNiHtQmpLCL/oHLY8T6BH+AaPXS3kmNjaR2TA+wxx6p4osfQphwc73lPTD19CscVtcSFJr4S2kVDr6gSP
# DATA kplMO9M+zjejav91bQ12XbRCflC1stugTBnhLh4Nd/WR7RCx0Z9Z8iV84WjL4MHcqrLZgudXMcHzSRyTBs3Mn3OM/gzhegrrnsX+
# DATA ZzByuooddJt0F3NanMoa1Izq72yGjrlg+UVsD72EQDhxsWX6HD12biwCZmhFUYS2eWPa/SOsTQS44ooQ+Bd8K0bj4Jci9YDlj4D5
# DATA zknxHtWfudNYTZDfxA7/iRtI4V6O8ZZrY5nq+ClgdDVx4AjNezXShpcSWzda28PLPKn+inX90qgQa3YBK7tURO62fJAR3g7A1APD
# DATA o/3lLhS7o0qxbJBbcJsYPSGdGH1nTl3+ls/5YltL99690/R+pvkdo34vT8r677VJeU3/uKheXP5hc7/uPJG/V8hPTjcWZzOE6jEV
# DATA 5jMMjHiUnO98eILs/xE5RvwT4KGIK4CBT/8kiJDYy1kAEITNsOzQiTPtKVFNViB6R6v/q77fKMoS5LnJGiemQTebiw7oBCco/bf6
# DATA mDRrqJgyqizKAgUOXlXRs0i0r3pCo4Ju8a6FUvxnyT2rd4znVXQrTMQXa6YWHzXhAqWrIVHwZxDUkWsJsYB48aIZ88W33TYJ/fHy
# DATA ZJf+uDT5CTvo35XYZuwWXHI9AHCdcCfUZ0fCWSUsyw+Y9qO+4sFeOU/hW4p/DZo3Ma0BrLLpuAeJ5B7pDtjRV3CiaH0GOoLFDDlV
# DATA dR6ou/Mf8HiQ4wP3FetfDSZ1uWwH+IRQQrkrbLoPvjJ2/qQsopB2Jz4IIMwMzsd9TiUScxgER0JDkvDL83ZCYBKM4NTvMh9ybU5P
# DATA vNxImb+A8w5Y2XKP3LgWOzQ5QidnhQMVrJI0lHreJ4GvtGts0DNyEABUshLba8VVZue+jACwzjNBX1EADTp1sbD0ua3ZnmK2tp3U
# DATA 9xapY4brKplh0QyWuS7alcLwS8tvPYg+0hlW8w0JJn4ixACCHcFVzAjAcbGBxJ/Bs4yQpwO7SLKZn2z/MKlyBv+R8wY8pnN4ygKw
# DATA v9hjKG6YhBOEiBD1OqD7pDPK25Js/mi4IEPTd/GLbol5Yi2wDi/KQgzOkcC1gICqc8fNxkmHLNVBtGYY5EGdsiz9+MBY+unn/Kxp
# DATA lnn/seZeBDWXSx0Oqo5xS8eJch3SZ9vQc/3H7YQ7oeu4KWGIy2NROtpcYl6J2Bz5B8U+plIb0xvdwinytC+615NmT0ngrQTUHlZu
# DATA OHbap0bAdRESlsO/4kZuu4bHJPc5PQbPhUwuVMO/lAABCdrP48RmCdr06DwY5t/hzmWNuwCWsdDt2mLNASXUmWNrtZgouZ4/Ri9b
# DATA wlAjT+MpLHP6rNGu0vcTqCB0xrMEk5j0HuTZtl3ufDcz70h2nG3rjuArtZzDOx2AktHBnnEh4BLna/Bm00msEzEbMy2boyOCz+rf
# DATA koEjApiv+A7upUmM84kDgGDCt6H6dgMCuRrEniSQq8DBLsCszhV67yKN0T8OzFjPwIdDG3pDSHsufgpvBj9qj2Ru6g0F4HM1JsY0
# DATA DyIp3PJUZpYEK6WM3F034Ekiq88ftBlE0+kQOpyVSMymD0DlIwSZoc9CCbJAB77NDgdBpnOwzgCRSN2oXMnE5aPBoCPDnbo9ZVlt
# DATA 1+N6nnAVEuJ8oaP/u4aN5tMMhY2ycruJ9NBtg6W4/6AHGRp7zUF23B+Fxm8b8zm93++OT+S4Me5Uo9MBqJjS/U6vheYy6nTVTi8I
# DATA hn5ap2riDo2FthcKXSd+az4FifCFdHGJ62lbddmPdsDFckiTVY9EbY0c/TFx2UY0DN67JvpB6jS8eRiN2clFi0trNNGvqyn3OxLD
# DATA FaRfRevIEkxS+iXHYGNMST8lCEp8KYftbruZtTkvdXVhpuOlBy77erK2HGga9d26pwh32DnQDqFqD/fvtyltpCJsUtxzF3w30OmZ
# DATA Z344MZFr+FNHr3GbxfxeSbwZRZjp2DL+0Ikuc3Vf8NmFpLBcKiaLSWEtKfPFTz0vBhONtpSCHVw5M4bTD9sMhpCyp0vJDEY7poif
# DATA TOBptOC6KjnYzqPmESKSch2VoQXuXE094VYwlMGjiZJZqc+rIZAyVxZ01VDD7HVcyEVMTQtofea6Lqi6iqqKcuF+8Lj4Br54o9o8
# DATA aV1ae785PLm0ph7iOXHkgTKZ2RHkUQ2Sb/RFJQtrNXjpr/94QEDEBVO5m/zWPLdT/xXSo+ODYaXTN3mklsirS/8KaY2PjQYDqBtv
# DATA Ti1O6abNQBGlouYTbMxHwkDi4mLobocubAuez8yZ8TjTPmj4R3kw7D889X6W6VI/tB3ULPe20NXNeLiR09skoEaDJja3Vw04WGA0
# DATA 6nyOGHEHHMuz3cGUwbqjrhto+HYRW6f5dwTjI6gQsBQbSYnV5aI3FzLSUhS8wn9ds5hdLNKHWMdK0d5GS3pNwTmlJBqnl07fJvam
# DATA sa/UNGLI0AF/0B2UMrvwJPI2aWbgoOefgJkPaUCSkomd5t98PFlAB1mtUHRyTDcsONrwpHXrtTN1NEz67vzvdPtyVBv0Dy1xWx1g
# DATA JBEj9lqNBCgj5wnlnu4Ar5UIuid6no0iV/ck8s6ewjhkAx8Jw3sMjmH8+h+WDb3yLPkZq6wtSlUEXuEOqjDsRSoX2qFsCvP9AP2x
# DATA i7hu16UNYNbVKZiY2Ie6VKoFE8PNB51eD+zRUZJi1m6m1WHsfMDPcXLlDJLjvPZi+A3Ss/o8o9Vv5ouLtdfYj4VXBXPj4eEzATu2
# DATA 3+RCKxfyY3tt9xB5WpQjkIehriuEGR5U7PS6M/tEz0zoA43dPuInoRYPW65GHNbnIpjcVosRKjo/JU3fMtQ/P8pqTso5JF824tdO
# DATA xkRLo9kCT/BuJCMeZwX0XW2NBy19SIVvxP1yWVqypQg11gq5I1REj5M5ceBxryOx3hZ999BIfaZsJKQpEcqQCHGPOuIJzLwl9Qnz
# DATA jKmg6s7KJpGGOstZwqpy1yehUDpHfMVc5BrrgDOx56JLry/Y+y5uY3sN+sMjTFRi6KtCtzAX1GU6qeu6O5GLurwshm7v/hY51/ag
# DATA kM+SQSs7VgTUK7GbvFzKgfk5E1MIh1EKpJBQmEoddBTKiMMgKE/QpfKRkvtICeEKiIVwUKVAsgmFNbc91zsBY/Y/xxZRlsqLeqUZ
# DATA 8uhCexrM0qjwvwFOl9Tg+7zK89d5LGGQ1LDZUStyh5p9l1pFLGV2fXXxZGwfbclmD1nb/pkcjatxV9dH+B1NgfqwxM5JaFySt0Qp
# DATA nruBQBjbBmDtZeTbWDQCk56ukjHUxFRSU60xMePI0jduGoHFMt9qXTAwVbtK6aIpqYTOYwfv+nzwvrmY8k0Jm4xrTaOoBewBT7AF
# DATA 3wIqQeo5cJwLfYE6F2B5RP0sNF5Qt1vw3HsCL4eZsPrgnhPEsD7/FUSySTJ5gzFLbywUJmPwYWLLQ1PwHEuq58IktU3pmNzl2/TT
# DATA RBRGgGkgUG+JlKOkdmQuGGfqvNo/TdrNYbeDMhbz4ozO6HazZVXXR7THgbrDN0eM4NhRlXdO2uqrE5COs+Nmq//AxZuthDALrt/o
# DATA 0n+m1+jSDJ9R3ef/KV1G56A5PQB2GjWL4PmMLsU8Rl1YUhuahF1I3d1QkQBht65qBHbXhTeIuWlVA+gGc62wNxL7JPd76g7W9TM8
# DATA xEjD0RbIh25/TH35PaLlD+tPiAEjijcc1B6kEjmtWLkOJC5FM2WIR+GA3P/QfoJWUPVXTq62X9Oz81GFHt8LI70wQ48Yul2BIZIY
# DATA yvJdnALwIAei6xQbPIUzJEQSsovaj01hU0Gs1u8SOIKPdzgEhQHmA4i5mgEaiuuGFEV1ItL5ysLEyYdPmQIE4UYAPnEH4Mt+1Sg8
# DATA hCPeRT0hkENPLeHhiVgXdnODC5uKJXrzG4uW8ZormJ2Wp5S2YCuoppisbPrqJ36OYTRpz6hF3HmC0fRC+UOm5A7xPMrFiW8KS7uC
# DATA 4F+UN06df5+pp3+S+LmvSAbzgDTxkUHKdZJ++B7DvVb7YUlLgm00DTY1QvVM2JxYNpzXk8uLkAMH/zPFMdzARqHL99Pnv5AcsH+g
# DATA saoHbvpadMEB400EJUdyZ1TdXpYSSUdRTcKUGZyhDiYBSp6QRWW5f2l5eZI7cA+1Q/VJVKKI4u1NiQ3qXUrIm6IWOOAXI37E0Zwa
# DATA JUlPlZ9qwo54wSXX+g1Vk+00IWQ62zXlkF1PuMLJNFcKWxJtyLlkAOnoXLIygSJ+uhJ3a06qjJk8Txy4YmYN9KK0LAFVwxQsI0U1
# DATA 5sgH9lIdP8d/ESk40WI53pRGlt/QLFndzkCazxLgNQmk9zqVWymhkTeHoGzEnKmE5o6VWnXB7FeSDUwgBsKC+ixD0Hf0BOu2GNJ6
# DATA AIAd2AhLFOjRParEYdZDeWuWd7u9F+JyKCNofyM3Lv+25cuqgvhfDEqEUP/z++drWeob80+Ke/1bIcac/msD/1HU5qRNdxJf2Tss
# DATA Xq277yxGAEoxuYf3Rh6IkCW22DAFqNEgGAN3WKTSanUyvP0WLGx7S7epGQpj2ou0C8Rso9lre0HcvGDFdEVsCCxPzjYhaJW/5wZ6
# DATA LsuD5knUKCtXuExwxP9LmCEcIU49L3QOFeP5R498B1LbC4NSp+JHJrF9nrz8K611wa42YC8V+AefAP3hPQKtdpWF85tPKlwFaPgM
# DATA glNUI8glHXWg7gD3IF1Kc3z5raz3Cc4cwSo9zU3ylSsxlcvmmMtBQIUHdW3m5gcsl845L3QYNOjM9KGtSn7DsLUKMhlLycCaQj/T
# DATA OHJfR2VJjy0gagpcKfqKvunJyp0pRmheB2z2SWKpAGdPcUSVQrgacUje+XI583hz4DJkK+rXNjpuXKckiqBwsHbVkHLC1HUlkM9t
# DATA aGO4dH6A+/mXVuAMJ4DwtKGom3R6TC003tn4cWQb/D/xhp+Qqhly21KT6hpp1+NoBs4QKuikybAAthhkce1ADmTKJP9k4qFVYSse
# DATA TIDnpsyYt44rQDXRTnfmMkhuyfT3XrrZUkKYW7Fz/66qLUN11FHqHw2bFlLAXn0yJft11T3j4Wbf2e4PKexmoP4wAEzo/r596zZC
# DATA RK+q/6WunytWwCeh6kIvU/vsRDtLxY9EdmR1XKRKLrgBIYykqfZEjAKU2OLm1zo/GZT9XKeg5W/C6Cj5/iYeEnsYLzUXpGEueDoz
# DATA o9S7dJA4rH0YY1BXMW8YvhaD9yH8PCsczDeTxdkTV3WZXzEO8oX+GK4fxiQfmG0qHFshxk4J3isgN3gciMuFKQ6gxRcF3vJ4cQTE
# DATA MOxd7ItpqIaBu9KLIlVGcdC+JZzK/yz/3xeFHdWZWlwBN8y5TfrYz8HDQJsJf/Psd6WEMdaiak8H3ulbgA5k32Xc6K7TVh7+nrly
# DATA 9bVnZc7+KmDtc+L1WS7g2nW97JQ3j60vrbuq+l7zO0T6c7ngdEg/t+xCDkWItE7Qe6bF6gvsuZm4pefY5fEzntC8pxK0cU+ZIpI6
# DATA +oZhf6TkHXJPVHupKlXsqR8Ul6z+IMuqJYDhPYJf8AeT/Lr3LJkDWSHcuUEm4U/z5ZJiTE0TwlZH9kQUA3NmgPIemrgrVhRMLQUO
# DATA B74wNVAXmDHllKxHG7SBmSK1g9ZKLwTeyMjUfogbd0S8NN7p+jkGKGY6WDgZEHlf8DqXjDOG7o8cwrLiLPCoimP6KbTS8pfnnPuz
# DATA xUX1qJQsLuoaJmHm9JKzHR2gLPV1QfV10EV3/mN1UpBkAX81gN5ciTQzwqiUBRNwH3ZWQZ6IkTPLHlBecQLZyyoEUXbcfli4uFpc
# DATA 0LkPULyKwfJ5XygS3761s/vW7Y2dxvb6zs57t25fRwU/NeQFSViF7+xs3MZYCetQ1C+vX3Vf+bV4GIKH1nFaXVqSH9Uz6cbkbwyT
# DATA bu1XX1m7uLqUX/ubt29t7TY2tq43rt+6ub4JUfrp8Wg0yFTdQGpmRdLt9a2NG6aYfuNXuXPnamP7ztUbm9dMYUeQGg+7WcFZVbPy
# DATA sLX2LlfhMvX2e5vXVc/Wr97YUL3beHP9zg1YGiVljNvhQG5u7N7evGbmutk66aAvibyAFYuu7OpaMajtvY2rb9+69Q4TROPtjfXr
# DATA WG2ULlghrzYqBCgyMWtJ2d2iRHChkDxojkbtYQ/j7P4OJn7YriAKdRt2fhGD42qVxe+nrtwm6SH58xL2AoyOlZseG+XuwSfjfVOe
# DATA 8/c1qknAYKSyw27zKKthlVPy12L9F2qIo6pqCNnVBXxlMwf4hJkBAj0AL6AJxsDO/bY44NEPuRTzKzfOEfMfCcqrnxIJfr+c3h3e
# DATA 7QG868vncutDXFKt17gCXjycDYp1n+aE5SRSNvI64LHDH2RKZMnNMd0MmqdguFaDA2tDBf4G41XWvrRW2b+0xsY0mRaBfaKAIsdR
# DATA OpL8jevGk/Ze0UXJ4Xd791hgYEes5rX2cLTdPoGd89MHo+3xvuLb7zAiveqJ9Rp+qjfwywfMJa/Xd2HdydnVsS0UzItSsns6oD+D
# DATA VbEn9lPQ7LGfI2IUS4rFR5hAgDR/BkDuESDGADLsh+hQ/NGzp6iTJvUsIjU9jec1Zco8fFkLNrUzorfJ3Z7pUC09Y+BWRdMvMw0/
# DATA aHZGhFiCDLQgIWqdk3Z/PKqtLpuQYitSAGPdFTu4iegjFEKoVq/V7CpJMo0Ci4QnH+uPoK7r+EQwHtydYxWDJknXxD49al07h3BE
# DATA t6ck7MLQelUyWwKj2sGxaqkyUOuvlVymlgBQAohuOXnNKeOZ6l+rJSsXV5ZfXY1u0D+gUwF4ETyCu5+b6Ca60o+St3d3t3fKBkZH
# DATA B7z1OOW93RtjBGZdVrt5yCxTkvCW4X9XN97a3Equbdze3Xxz89r67gY+rSy+gf+qszR4l1q5tVV1Ow7zgmaCAf8+HE4wGL6yWtpy
# DATA 0ec+HMj9wMsSnmXdyvbGzQYMuzHqq2P1Nv5dgE6oo7dYrEiycDNReHDAl5Tku8EoFw1+WThoohUNbgjWdBadGioMv4OHSfI+1ffu
# DATA xu3NN3/c+NEryz9Ux7OasvUbjWtvK4nB+VKd452T8YmVihe+3b2xw+708Of9lcYqe4o3W4rmgIhh41VO+mqKwfetAGco70UyOR2D
# DATA KSUo9JquwsJSCZDVOqPjJAPt2kgmRfW2ByZ2dUMopCurr1aW1f+tpPokM4xAjaewCmHpDwuVlZJurux3BRLlNjPFSx9E0oJDB2SC
# DATA Hgybgwb1pqBKk1quPWwIn6hp4QrqU4xrPMwT9BVJ+hRDxYFZDdrtIRLLvrqlD9Va9ocnfBBpqgEGJuRXzb1WGZB7wlj8APzjHLQr
# DATA sC9CNMg/SXoSG7hSLXiZNjzC13+YFnNuLdT1rA3stFs4TN/a2FUsDPbR0kplBQSCt9XUVJMzmaEJPLuml1LdrLvgLgCSg/r/kL8N
# DATA j+NiMW/2VpeXgY11UPdDzSv2eb/wysqq6OmKeyt1oLO15eX8GbLYvX1y3trhY9M+QjfBYcg/Q+UKZIgYyCvrttuDQoVvP7QMLlux
# DATA ExnzGnyAGNN/Tiz0yy8pKebzT66IUo1Cdz6RPMu4pqUoW8bE6f9BSWXAVorCX5lUjWLNx1+cB69g7iBZB3wL1LFlm+xnXgRRhlFv
# DATA 0xTPXqlDh13j5f0wpQQEAAeULOPuXVaXKjw25YviBFjPlbs9q+hetVrPLeeIu4dpmtLOTM7OFqwqxr3Ow+rS/eZwSe27Ja3EXhqO
# DATA e0s4ERXY3FBlgirXBty1+wf97pWFMxrcRC7patfjVBiCvkJWkqzbsI/4SGujrneqR79sgGCf8/Vg2LmvXrvfSl+zBNl0ZZX/vUhF
# DATA QFRaTfq9KwvWEPB2lSX9w8MrbANRx+TSOBsuKaY0bNOkLB2PTrr0vjke9dFrznzShu3QQKDJteW1ZEn9p2J90Gqpy1uzpZbiR+Vr
# DATA dDKXQRIt36ILqaLJrNc5VFJ190HzNAu+ug2AKcP2sLzdV9N/CpJ152DEnnzlB8ftXvlg2M8yfuJU0+2TIiT5u39Ilh7CBIC3zJIQ
# DATA BR593Q4E66kjorHfb52SdLR8Rb8/Gg4OGiSu0KGSXFxezrz3wPamvQfugH+pq/40EsQuIglSBZOJOww1irt3K4U3XnrQ7nbLiOuw
# DATA VFSjUSdb7xT8nK8En8Bg4VQlr4Tk++NhB/+zlNTUQmF59f/UfmF2cDhsZ8eFmDtPSVt/xZ6pT71UH761VA1/OS3R9qlp+wYK68Qz
# DATA sLSvacqxhnqPkR+pFlawBdRq9dqjBiogKCCOWzJP4dDkh8g00FNTMYfuIQThdFP7HVW/tnZRnnZ6+/2xWlp6cRne2GBFdp2i+Cs4
# DATA ddsXjPhdGDA8H7N5nwXtD8jJ/dkXiSuA4rU4LS7MUoG7/aq51xyd89JakaBjlBcBjyCKcPtEB1NEJGMTFvcpxq0ygOg30l3TNa0/
# DATA 3MMTIBYhx/oKf0kjixmGI0EoHTVBsXQX81KooAT1y2R9e7PkrA9gVLM7yaPkR8PmqblKf8kRdJJTBU5zyyekc+jTcgTsJgfa/bcY
# DATA 6ATxhlvqvrx+/aa6LrkJ6T5l+eFjwMOGO/1HdjzVp7TSJoohhvauXcSCANMAFzfP6yxfr9TtHx2RP9pZ2lLHGrqFpKChKXMa3bQ/
# DATA EA+Qs1Qx6jLwaCh0cRm1I/AIi6pHr6TMACHuti+APwggBa/HPcUEs3I26kO6FviYm4cAfPorUFDqCP0z1/CtvYzZLtuyHWomQTXj
# DATA buekM6J6en3u71ma9Q+hZyvLa5dfefWS6pA6dlvmwWQymc9PqjkYSPIyGjpzaUlaI0n7yJXVLKmkSi7WSzEJGZYrq+0dmntWVbQ0
# DATA VeT08c8YlLG2xzboMt2Z6NyDk86Ypsm3NasuqVVeUqNY4gc5NbfaYGDMGv1ezTadtvZxNpUY20LbEYIrMRaDEiS6o+PTdOJYVckk
# DATA PvujSbQb9BqxEVU/RorCwAcpvXbzennn7Y0bmB/rALJflQ+zHRS91NEPh3IXDk2YupUlqgM9zzHJopoT6MHKMlotWJxAos7IIKwk
# DATA H/R1ukQHy3DUGKirfr9FeyGzzcMhTwmMtqCCHKh3lFNmL9UMJK3HUixFSEvbR6orlytr6QsTGV0hj09Q+Kql6gJ3sk+1iQVMzfHu
# DATA T2CYd3avwToa+pIeGpHK8oGY0tw8Czg4anQykP1Ok/Kd5PvfP3PMTJOk3HIeXr86CRbz4qy1XF2e2GEbiiZz5pp2DG+c6g/Lze6g
# DATA 0wP2OO9ey5sMaEedN9b3eDWAbpbLmdoqmOsNf5F1H0DmSStNTxX/PWmfqHUuD1BEp3dttY1wU2EZkHqpX/Db6xr/g4KvX1xRODL5
# DATA V199lV4BR4K/lnMHlL+0ximmrOR+rC+boz+Qn/RrrqzlO2exLVVKTanDlpCRWYmRQoaF/zpBSqHoXM1P5EsiX75VMP9LvMmLftt/
# DATA EXhoRD6tiRgA3iTBa3CGubxcSpSUPcn1RWIBbHrOLtuEEZO7KJedqE7ISuHITE9JzE2jLizZnu2bE7i61eP7N1yjkHpJ0qgRDLz6
# DATA dk9kD6S9XKe7KI5g5Niawp3t74VTgzR3SNEvzvvYvouJCcEKg8SwEt228UP9xQ7n6buf4BzVvg/t2iynHbYhfullPrLNeKDvS8gA
# DATA es0un90vFyujY3V5GNZeZ98tiBUcFYaV/r03lqsrxWLlAMOhCkWvhHqVx78cLvPKLC6zshoRBlZdYYBPCIFYg6gnDxVCJ2UzDNJw
# DATA ay2QuZGRcMGnSDC841dz9gq9zdkV9La6ak4z99B/69b1jat33oIxnYy7ow6ob0YHg9oyCAFMdOnl5eplUAjAzb1Kt3f5c2ncGkyT
# DATA AuJCa7A9rkEvKawBjOvVJUUjS9j1Jf2qOuzrFOJlmM/qEvzXPCMVa3XJTTrjNS7RZ2dWRRim5lXjh65pf/EzivI3rvqJHe4mf8Iy
# DATA M256VZqeWCrw0bCJV229epEFJ2XunhEW2afc2sARpAunEO7Gua8wSpQFb0RW4cCB9eIiJ4u+NUfs1VodcxHnMZamEIeSG4Qsolq9
# DATA tJQE36i7ZuZ81D9aysYDWB10/4x1OWTaYDVegnkQwSvWDeZ4OV8f9Idt7Vcc+xwxlZ1S9bhUg4okWMMYHdXdeJ6I5gmPAbIpWO+L
# DATA 4aVF6LYuvqbByNBsnr8ko24GezXvbLdMJHlMC99WVyqrlw3fihHnwvm4DBkgYH/bbIY08PC00lpiezAWQoYznbO94NSct9bZO+Cc
# DATA FT548EAqjJkioI8e+7RYlr2AL8ofJ99EBJVRk82OoQqCqELyiODtgJTmhVnBL79qP4wKo2IiMVQ0iSwlsXdL1d6ufsWoYtAFtXUw
# DATA R1lFzDRlz/iHpzQXD0/D7lJsVjURfW6KGUGsniKOh84ENaeKjL1sbLn0zhCkaz/8ZKrX5LkuXnZA+VmYILmakHnCfUNjD8TnaZso
# DATA J1kw0SEkCq7Af9YKxeKkGPbQB7oRzjr1nhODsXLGa7tb1VwtP2nkxTGqRjphR2dfpCKbpLP3Sjma/GLMCdoO0gOiUPzDCRYR7BhM
# DATA h1cCy1n/gW9KYntNv9sC7v7ACxrgzCKOwFrA6oq2PyqI16oGJ0QLVQt2SgPwh4Zd8bfv7TYch+UU83td36S/0EvX9rOFv8V9FmCV
# DATA TZNePnRVjlL5yK/AF7kUcyaGhyaoQf1yYhDcSJkwtkgNm6IkXqrB/JFrZPu0mHu3/+86J+jTZ3/mKCJMtI3BtJBmOxI09PzXBFQA
# DATA NVNkoyINwvohf9sDtQkUnbRbhb3CCTkCgvkZQiD45w4l/TEPrqtLY6eHu8F6evu9lAOzMRsUxwjexOY4KWtRKKZBvUDCaege0R+G
# DATA dPi3RTXgZ6Tu9BCFJpmLYAej1aWfVZjWuD+Q+O3anZ3dxu1bt3BFUIWuT17VWyuL1BLF3arKEXYYtV0GmUNeCcishR6G/WHjphkZ
# DATA W6joLcR56nGa5TXPOLNNgT+g6r+X3JJslaPjYbttMBLLkMYIU0DhAcwtnjRPk/02uAa0W5VkA+FUJI6JK8SSgME2aO53up3RKV0S
# DATA S+KijPZGEtQUq0A9GPBZBHUY9ZlTdDKBVjRQCbRGXzcqNIqfIFMtjUEfI4xmarA40CQMHVYCj0Yz9cVgX+qS1mpKBRBtA9ZGpD3z
# DATA 9GJd8HjhvIrEVflhenZTkA+G6SeeWmzO+ig3l9ggqeoVTwwctrtNhkOj4mYHVORdY9SnDSUR7jbuAhzq/oedrDHXt2HiZB08wL2C
# DATA tQVjszyoUHIkkFZW8eULpXVzawPXUq7LebyCyT/iK7AnC1UP1yLcxfhL061FRcToAz4QY+8IvvAJGaO/QCVuyNgjeTfVdZ22703W
# DATA 44FkcFURK+Aswe9rzcF6q8V/XR/2B1ho2LmvxGow0dadk9g7900EITpyhHX5KOjNgX3QSBhhNTlDB93moKhkIXWpR+KzU3tdW1cH
# DATA Pod9NxGjo+AF8YOzZMBodLSqOmvceEJYBOgNHTjcL/jHHDb4yzpqIjGfMmLmk1JRTVefvK8kC6MwmczPCewmcCrz2yifuw2dmXPm
# DATA 3CkKtTh5fsGo80con5gKqhpQHPwq47sMbpJYb5pzTa7iVRqUvXxjTiOqHIgas1Q+0YKh0gYx8KzfpYWJBAdC0lWT/TWGZOEnf53f
# DATA IUSAweW9iwtuqvHrmYYK7uICRWMVZmKE+/5JrJUsnBNKozg/fpSNhpEPQjpzvJSp2ILI0Cgw5MkDETvPf8549MxH6SHMwFfPf+2w
# DATA VvT2rCW2mqGQxs8cIG/7Ilk5bj90MvieTcV1maEdgY7wc/izaOe0FGSXQ52zqaSZdE6u0iDmD/HKSJSjs86Vmbxlt2V6k0UKw8rh
# DATA TeSSYKVRtW52OaXBnI7araXU9UOTXoYwDWqZIIhBCpTgulPjcwdbqaJcQce40xjEmcj1hRM65F7A/sXdNQHVWNRGNleO2cP04zG/
# DATA MvXqI/eaxplXp4M8aEmPvJFxtQP4Ryt/L6G8fN2ksPTDSQpLf1gqEze/qqlYVyQEauqwqp64CTNVXYoHH3TBOXhL8rDuNoebvcM+
# DATA wLAi+iP/Fs4LaQ1R+dFWUld71AT7UAE8TksJxE1B9gIrmKY/Qtxu1ZHmSHWDS6jeNfQe17UQqKialWWgTaiyAu44jrpLHgJiO+C8
# DATA Lq4i4WMz6tGlZFGexw5QGCNf6bgniTSOURftVoa3wax52E7QW85S0vMXldyeQxgSdGTBTBRYXBsDtW/yJggHFM6nFPSzCaKFRrE+
# DATA U7Eu6TV61BtDKuxvp2GpPK/xTAn8kGokp20O+cRCjCNHQKQjaGeAuhK80pvlOukcDZnTsdSAquKDkZ02nlsqUO4gkzkHVqeBy1lb
# DATA 1QRysUTIDfxiZVn9j/v48ssvX4WJSSgAgFQN3f4RgsYjsXBGE0DBRKTTnrq7A+Gg7zoAXd6HTqtutCuqsoUwR7fNhWSTHOBhUEuW
# DATA F3TUl+xByGBUgL/6+z+tyfDI0DN8n/Jqd9QerfmbGIPAeFq823ob/WDgyuG/Jh4HfblQS1a8ICPKzEsXYKyCwFLpihdipIwxYY41
# DATA 0bBdw6+VUNbcV2LbeNQmySytVFLCih2Osrzj4k4PN2ov3NUIJquxObAbaTF6plEvOhnJhOKarh8zkqGeMPWIibs4pVeaiHsxhgP1
# DATA hL3h+ik2Nlm2mmR+Z6hYXVCQZvJ6YLG5gKvpjZSgD7PbjZY5toGZkTjx036nh0kGFklXEJtG60NfWcGUPkdfZYYICkFxAEVqLVvG
# DATA yZkyXrwoYrA1hfH4O1kzHUZrRFGJ1nc5EfcyEoZoT8LJPegT7tDl/qvLyxAsAkg6GYeDIKB3o3/PShY68xJLfELtSWtQectXoea+
# DATA Tj/guD0ejzrdSquT3WuMM0jhxqtZOQR16WsOhV5ILq3lHb9mpjfV7jg87BxAzBPg+N5DJqvErBNkS/6Gtvl+VBUnpzIfB7hfqVfh
# DATA aOibIMnqTIKUCHL15Yna/+CL6Vb+PYBQ7o4zLAwhwrCBGCVb0fCYTFuy9y2kbDlAyGwVCzuGLpeclcWzIH24nyJz749Hg3EkF5n9
# DATA xcGxIoACrr+1JzQ6/MrKCmkOEXw+JEbSU9PdJY/0TJC1Lh3fb/tdCG+0lKPNVgGCpPVnpeTSK69cvJQfdQv8BmuZFXIcWckHasZG
# DATA w3EPVqOVE0lMM1phIHxoKF7OTEuZEl/llOX6DhV9HEcgw/tZ5TA77R0UpJyaxF6/4FoV8QTT1sTBaUzqsdQlQjYO71V/k3sCKQrQ
# DATA LWyQWmoWdHdAyG3aKHA/rKCrIrsxsP8gGavFmXAb6REqB0tRC4Le7beb2xv4vD0c+s9Z+umcYFgOWGCaoEWt7MKTwgp44krxe51u
# DATA 1ypeaTXbFFsDbMt6jldfASCBqFBVROvDncj+IMx/ijwpvaDhlYIrpA+jDvsSSHA89LiMdIlfLnhgbHqoBTvhj912BUPUrdetTvOo
# DATA 11db/QCWxSqsmqLNtXLp4uU1P1FDibqSKfGxrW6BB27iKacSv0XtxyLlAAqlYAGfGEc74pXga3etP+62GDZaiVgoKgOzQBnPHgNC
# DATA BjKfdt7Yt0CaRj8/I8pt1GQMoOaanbiMszJea/bw0qEOne4pbizr7Lli8qqZLSJJIVqgPMekClBTeFvShA44sd224jbb9IB3irgJ
# DATA gC+KNUoB6FaNdm1iReI+AJwfmzbIJRKbGfSBauJnWw5l2a+CNSRWk/Wag+y4b2+KAigNVP/HPXs7q58lYkxYqJbDo+zQ1ZGnyoii
# DATA 33wvWU84VE7I4qR5T90X6cCEGD0wrXZJdEOoik6bqOhnYyUuQdaQdmcA1mKu76B/3EYERhlbJbmt5g48jJN77fYgczPqmZWnhBmK
# DATA DffHgIZZkYTpGn1FzUHBZq78DuKEeaCinKxD/gZ0DychTIm7asTtBp0A/BDQPuRPb3OZTjlAUrozzCyKVhI3T7+42SL4oaBniZ2X
# DATA mS2+MNW2Bvr2uNdDGSiSWojS2n0K6jn6E8EjMLVOTJv3laMW53xoNio6phMind/HecGgNIgpyUFZyWwVRm1vXavG4WeAYYQPWYw2
# DATA Xgwv2cpqRjp6MZspVO+Zes6XeNSb40fT9KWWuj1yJ9C3AMv3AlM0QdKjTi93p7pyBgCqYsIg1kUqKscpp4esjqy77mu0p6ca541m
# DATA GyafFbI5VmSqr56XyzE+q39BfO9P5pg+o8cJJtFOI62mqcXA6RbTdPZZIKO5WniooUJ8EI7tqnfbuE5MJjNX5l6Lsn6qGxVcKMYd
# DATA yIuk+GDS3M+A23XbR02ErhC0QlOZIWc80Ei0WoKoNzhM1Z94S2ORJaskW5BHKMkeoOkauWUXAQYr/n1ryqmvzVA4UJI0MCbLoQfn
# DATA da7N4F8ps8mntC/IqG/boJ5GF1eSmBHO318Y8uBLSe0RzZ+CUAmUVeE3Gn8rX4Pn5z3aE33kItPQ8Kjb3y+ki2nRo1jQ5XEmzkqX
# DATA cNNi6ZKisGs62662crrpd4vTJpKtKgK4BzksHwEoNsFCQFLLv2gYNrD9PQ7n9Wls00xRKWqtBgxao8NZI2QVHN1Q8zSMqL61TQGW
# DATA ojd3wL/PJQmhiMfPf/n8F4JKFcWkAxpDokDfQJchexOAA/Lu4sFiySxMvZ0fUDrtHgCyFWI8dgr3RoBmh02jV8Qs833RhsHGiR+S
# DATA 2F3AvyScw0+r6Hnm6jyikW+cPUMyHdylYOMwuqKFpAjKlU5/nKVF5/GQsiKfBjuKUMwIW19qtg3o9D6uI6Z3c3qaMFwa7vka/+Iu
# DATA Q+JAtLy6SjsEU/PKEh5bpDR3yZM4tGhxaW2CFwqocvpG905CTH0hfA8xvghyhTJiKPb6BTlJ2cnmBZBF7Z5P4VHYVWcygMgglgIx
# DATA CJbUq6WHw+YpZ4aQRaHhnxA+JnyyP+61uoBsMbejj93oS7MpG5GPacZyJ+y33qifyJgptS9Lq08l8wDlAbYPIchLoCaQswE7Yhxm
# DATA BPYSb/nJo/3EXVjVE53VAFFqOfus38E4/cgGZEqx2KzaFHaGSLccSb9TpypyGtugcfZpLHNjJa//A+XZBbQ4D/LT0NiC9vvLKBcg
# DATA LDKEwlhpC9cTVLcpMQwFDnUt7th6Z3C8Swb9B3Ct62cZpEzGnHLNIVkdeu0HVmV0B7BciBJEys2OUaJ5cAxJF+Q2KZbBZu80YdUK
# DATA +NBWLIUN1dIhJCEL2wokWyUb4PntyA0otBtZITg2LBcO+zP2ObcadJw2EGqInDbwT/YEBdUEgG8y6nDVNzBgCAYqsdT0o+qP0/9l
# DATA lVuN29dvbd34cfI+/RLBXD/YuvXmrRs3br3nkuQoxlu1VtQ06X4V6EisL0llZX/JoL2g0m2oi7y6HAtiL+czqgYXxa/l7M72cJ2s
# DATA PB9l1/vmpMlJPtLbUnHy/33wO5QzJOmZna8ksdPOCwahRKSiprYtwiMdqzqHT74LWIVQqAqef7eIE35KhwaDJO35wNCEikWXQusI
# DATA LHopIuB1CaMcWciDBz7TImpdiGXjlMklPK5czIGs0mxRqCZtELOJLMsztu8kmbdS5EJuIzcBPcX3Gu5ZXchvNfYl40+pKyEyA1p8
# DATA RVmYwPELXG30oXv+keTCRPpxc8Y++x9T8hKaHJp2Vl0v3A2jc/BKKWmtIHPQ4l6a4NcBQ7K7IfGC9XqsVkB91YfTn8jvEXLyfCCI
# DATA beiXNb0xYmN6Qot1Jw2hfm7mnubzApg6EjuQAa4rKJibVEJfJH5C6GdPrniwc3gQwXrJJdBLPsgJhypsJLFahxnAD3EHf4jj/iVg
# DATA t1knWyURrDs8JVWpLzDp2AekzxFMkUc5SQ8VA8+ScrcZ5kggx82/qIJ/IFB6nSexglk8dPrvD50MghjqhAAk7BD/GMmJ8hOKu92z
# DATA p5WwwZRo0U4Gzt9gMnCuFKYWKdRQJqt0NMpDmKHh2f9tEGTV5cz1psU0iKrKsEKKcQ9rg04+IbL0PXMVcYb1DNtH6jYD14P4oGm3
# DATA QhXq6lhNDlrRTaceJqQdluxRyQAjBtCUyLwettY4k1SWGEga3/j1SGSCAYkoRQBVNI5GWbKHVEYPRzrDF4V9lyRCu0RB1SWexRLf
# DATA 1eAPiI12oxhc5kYuPfGU5bg77BxNaHSMzJfUU9SuZQMSuljeYJv8rCTxhVw9icllHk8F7rjRImP2VSeSz/j3kLiY8gOSAI4b/M3N
# DATA Gxs7MMOBsGvlNQ7zr3tY0HbaaBmyATpWs+EeK7pRWCfAsAbnnQJOepGTcvBZhgi608+c578sAdf5uUnQ/NROxxpn5GlqKNPQMJIn
# DATA RUMLBI5j8Dmg3D3BhgN3cFOLGoCvK8DYJvjausKIMdC80IvvGQaxmfYQtbWol6BPvCsTTtUFSdQrPaFVNFU4Yl1epLTa6+jj/AHi
# DATA RtmymyEKFGZy6i26i1zMawePUznLEzeNlAYrNW3oIAJznlM4ad2Xw2b3Ll8mCicUpuPfXCqCI23umWB8FU/Lhgnp/MHZ7PBmjlMR
# DATA cpCj9qwe/56OZ6T5f4zAf1VZkDlqz0UT0+nCwhnzJiZoYF7i8AkkaCJCK9SYJ/GZnc472Ihrwdm5FMTvq6O5wpda3tXFverFVfdk
# DATA mbmHAy0Qr390O/MCE0WMexLu20pnVWoRQDCOcyz3PPQeX1ai9Fidc211M+rcTW4N0YLcWkLZ1Zbh/kIaLP+s+Jjxhz9A7RQOLcGP
# DATA nkhm+GdPQ5lRWnktrPH1JbJZMdxUeXGJxWigUxCkPdkymo3+2dMSaKO07o6+gnxAVjb3J1GtXNhZEIR4Pv5jDnmUUNKY+uUSP03w
# DATA TEs6Ql5P+yNOmwAiBpf8s46qcpCSQzH399aF4wnfYB6rvmG28QQGjh36jK8QeBMxs8QXQjHRSxZxbfPxtHdKTJBQ2uc/l7sQm9ZR
# DATA bajlFCsdFsswwivi0gsSppFeSJWDME28a9Efe4i+oEf4d2V9eDSGprbxjdYEqR1bazSUDN5oFK0v4YreaPInhbQ/aA8lTOrguA96
# DATA kRpj+mCupxRDyTI0NHAiXErBjbAyIOOUWdzGb+y/dU5djBNIGcmnORTUO0z3BX8fEe4d8a8UMZmz4zLtFiyLCXasBw5XAvSY4CGj
# DATA bgbPuX/oj1IeD9TJSHHNgDjVGQnYD/UmG4Hi3HokqH1lxjTAKeg2e5bfAzbI2lHvsThT2V4SQ3bG0TXRjEJDZe6APVk5r7nz8Zcy
# DATA DnrrTAYmo9DLZVAc8B6EekNxYIiSTrnMNrXilbwCbKLLLyBuQ1ObMRdBm0Y9ATu/DXO6TG1FEKOmdJYS+ua+p6XOf8+kRODpU/uC
# DATA GZOn1DRkpySIzBweZTXQlE8dm6KtaR2jxLdmNXJLWgomvfrTGjY7hWMFa+mMniKZqs/KkuayiaayWopk3MAUmdObRDyy/tevA8CR
# DATA yicEfGDILi/dRN0aoikzZysMsqwrwMwXV6Z+x6BMwaeUNWNas8Qb3SXJbcuvHkHopzOFCHOec/GdT2m3zddLV0wNuryyPHPr40ll
# DATA VlnniUf9CuNR6xrp7ey1PddMA2Z4/ltOEceNsnc7l8V/oHRmYADgV0Uf7joHCB/qRirxUzviTQI/Rm5WFNixeJV8SlRdDY4Ynfy6
# DATA Son1hEJ0p1fvn0tVLypZbj52jT5YJjoqBSHMftf2HFg/SxPQ7jX3u6gygSyk8+GMIJqJgdRQVLR+44aLP+KYlSQvAF5QUGXnvB4Y
# DATA OBX0edZRAPZSAxAZTBn116Sd4f5H0YKdEG6nExqRzowiJ708fNYCgBFMagCjmzbKFiHEcJz/fLMJBu9YrgSjMLSWX5s43UgEvYjO
# DATA 3LFK81RRBKVDp1IEm9jrp9OJ0xZSzfTSgwa8bJP7e8UgL0ytz5ckz0XsDAqRBy7CB3tDHVT0PT8olpJYF+ecWquIOPtBB6YPMyYd
# DATA W35TER/8czKNqXK2dR3jYrbjvhRzh32eRXQvFla6mCyDvKT8QhJ+ZuHYHB7JXBN/8Cclvd1no2ybmmS5NbvgB0TrhRkz6l2ObMKE
# DATA Fw1+YXWaexmfwbwBTe+Efx+zFeok1jndOM+mi1yc/A0tZve83WLvP0oEg0gJXN18y4xPuDntLchAS6QyLHmqerOpzWcmnsH9lNc9
# DATA zIRgOoK3jmKEW/D9oGG4hvnIuhE0nP0ZOARPG1opmTUCz8WR3Dw7vcF45CCDoNNF1dibQEgn98Kq4+qFLydRXkYxP4aTTWF16OVu
# DATA ocvnkdm0C7yTcg1LzUVBc23Zqc3x7p2PXC1KnWub5qobwn1LHXDwd7Go1Q1cjJK1BblfM0yaqrpZvM3VLVlrQUmd6fm5WIrWllWn
# DATA UY+UKsw6mi3E6ygbZa6H9qcZYw30V9N7yKUbXHpaT0Megj/4yxndMipFX+QpAQQ9Is1IkRhpnncGOb2B32d9NuJPORmF8gPk6am8
# DATA wZeUHHdwaytdiQNCw21DDfxK3PcIBG1tQLGatcEx61E5znIsn3EsasXuVBKhnauKFabtTC1kEqY5/SCc2HBuQWEwg15CBUPVF+m1
# DATA Oj3EGY836XSxeJ4OiKZ5zj5IOqhvuhsz18ppa+aSaeY5xwV9ZtMoYUOT+V6mFOGGaLsUB2CRyTx9YIB7swazBLbOCSbByk5NrLX6
# DATA u0IOND0Q1gvLFhh0A/lro2HtMY6WLAZ1amR1x2losER5G6ZYd62AhXlQFiHQ9HP0YsOMWmEcku6I5M7EH4VBSTJ/OMSmPzNdpbA/
# DATA FzXlivVeh/e88orPDlUZx9HKSXsesgMXjV6z4hm5dTUC8AwSIQNUeLoIW6YkzHMdtzqNhX2UTGVvlHPBGo9TMI8FRPKXRV7Yzbjp
# DATA J0uo/TGN9vr2u8jkRhfCfuhkAfCTPHydE8qtYgNArLYhvJMSRcyoZo5T+MqLnYFirHQE5iCzQSB8zC2WiMZO2ynKCLXuYFOIy512
# DATA WEUvtb/orMjgozYN0jnAJ9X8YdZNJa0GKkZOIRRjHkFZO+eQ80E02ZB8BaRVpYSHhvuHpWgLVt30x/arYkw9Wk06AzXDQ0Bw6Ay0
# DATA VKvVKZzp3o4Kz5skRJpc8D3/A52yVO2AjlqxAPhhCRHkQ9j4vBgAX7hQ++M+5+WGWzbFBVhoLU7CEFODFT+Qf5VDe3x1phS7kJN/
# DATA RWwWVU/hk5Jpp2rx0Em4ZGzjtJFPqrFcKlxuPZCgrUpmS8MLC6rdBpJSo4HDbzSASBsNngAncIccMhYsOJwQcAVwcRAvpTpN6JA9
# DATA /m/Pf6E27x/I+T3Hu2emKzg2p/gLJmgDcYaCyS04GwSH2TnNRu2TDcqLaA+i8C5QBfa+lLzTPuW/IH8H/3lrh/9AJI6/3bm1dR2h
# DATA dvBp0Q5K20TVDGaR6PQOuuOWIJ1haoismvQwsh7HnwzbPyVgEc46D3F54243gQYq3/L0VZJn/25C9p5/QrAcDJOgIwdKLlLHLynk
# DATA 0eLLFETg5k95/ktAlDrXavzV/5r/U7tsvwsnp9pGlcHpt9IGBMVfWlvDf9X//H+XL128qP/G5ysryytrf5UsfxcTMAYHe9X8X/3v
# DATA +b+XX34ZNpLijmTKldA/DLWTPDSkdOsAZuCw3W03M0A5ogjTlcpq5YerlYWF3WPw4bUL/mysRPRkdKzOCUST4wARxADtHEFam+N2
# DATA d4BxKMfAPgCnUL3tj4+OF7CQvlAku9e2ywSiethuAkgRmlEhRtb0kdN3J8fN+23VuzZ4loPVslVRfWsPMfy2pY7UfThKAWir19em
# DATA 6AP7kEDE1oftgzEF/gNwFkiUBGK4AEC6s46kgH+ku7PGc6wOJbvT6XfEcZz4nIOfZv8J+//VS6+s+Pt/dfnif+3/7+J/6Thrs4Cd
# DATA XllYUBshGyVnyfawk500r3U7eOGmX8kEAxpwWxfSvxngw6UDLJMWr/C3P30wsouBOPKgvU8mhqJuYefarW1MBHILk04hkOvftwt7
# DATA lMQjw51TFThw31k0qwLmmxJOJQcw5/4IfOL5fVZlR9b8AiDqq2rq0MPDcY+QOYbtcQanY2HYf1DklCWSX6//IPnrv4Z/KpzRxYmV
# DATA thtCr/dUlTZ6HPis/XCgJmh9hJ/2QKZ6//3EefE6Ztu7DiJ7sRh8nx2oS0FWUXz1CGEtajyn8uT99x2ZfK5vLiQrMiouyhJi5kau
# DATA 4HwW3U5xTSA7nhbw66T2erQq/F1UMz1ZWGhCdH2iZ1xdE+934C5SIOoqYaoNSVsmawBau5eW/m5vufzDZvmwfnZ5UtZ/r03Ka/rH
# DATA RfXi8g+b+3Xnify9sjr5/lIFEqNjZkiYf8hHYU0cpEnoH0rStJdIywV5J1IoTI9l7l5LLq4WAT5UUQasG2M7bvbw4i7nFB0w6ruW
# DATA 2jSdJmRQuSJgeopuiJamU5JdXpzg4FYFDmMJTVulOehg8susApBXd3qdn43VvS95AOdgVW1vHO8kmXDjS0vJ7XY2Vm1jUqCkiQd2
# DATA Ge9kArlVEscMaA5p9BQPYYCY6GBEoOphswu4Df0DPkcPk2Hn6HiUVfSy6Q4rMntJ7y95WpQVxsn3p5KdwBLkJcnBcbN31G5dEWsl
# DATA SgOKfkZ0X7EDrsmtl4ZKKVS6ajmh9pqZQbWgOVOIUMowfZjM3Ooh0SasWSmRXVs1mxb+U+n1HxQgamBlOVlMLl56Rf338qU1POcA
# DATA Mwi3RjXZq1QqtIE4YMdZm10QofrdVnI0bKrh0P3soD9UIx/0IXEC5OwDkLWxEpvUOiCssAZjq6i1BZFCautTssEmUE/zQGOyIfCs
# DATA s8ggg3WQTke01DhGFoNiCyp/z8U8rHmklciZfVFaEO2ewZxPSrgSZzx71uRNJs4yM7NWR1IFJM7CGS+ZOvOGsGxVZLyAedKFoKX1
# DATA 7U0rfqXTVIt5E8wOh91+f4gMlEihtY7JbAAgGBNKruBi6g9Vd3I4/BvJGQDaNUGNXQUE6PYkUQSlCgYtycdhQ5NiMilZzpTAhEpq
# DATA Tze7R321YY9P1Eje3gHHCqShKUz2zf5wk9hSlN0CImivhUpHm/MGD2VDHXSbnZPsio1trLpFTwEiVK0CGe9NFaapM9192A48gLoa
# DATA gNoKB4AvpapaWkzWk1bn8JCgU1GxjhCZiuXcUxRv2CpkeskUG4O9KCRcSRaXkolj+uG+KdKlv9DCTGc50AK84COA3yPfrNnngHUC
# DATA 4v76Jk8lq1Fnvxj+P3Xn2KxfOD/UVbVHo3eMPS+O4FPUeXqCw9mqR5/RprZJuBNnnO9IrdQBFB8rlI4M8021xmppFJMWrN/m8Og+
# DATA 5XKsATS4zA/NC9UOOGtq3ygx5MwlyshM9kmyBKBuzLVdIJn3jQpV9S6pSN+okLj7RiUbdOFeV0kB3jZ54w3IFvR6LXkV9nigG1ZS
# DATA 7GAE+RCBHgtaNkbknuZgsIS6dxpitiSCNX9UHhylxQr1ZvuoWDiLeheqQfQIumwHCbOq50kdhBU7B3IJEmhVk9XSjHp2Ce33Zqer
# DATA ZOOqYj2NZcBo7bS6be/VRXoV1DcBrkQJ42nkqvVCXreKlawNMKLbzWFTkRQFS1Oy+SJMb4pRegfA09yWgINC9iBF7UoaiIAYYNP2
# DATA fabAa22TqvAYFxLKl0Cus+eNEng6wGY6f0+CDohIIIoQe0uclNPhhigW+Nk0RmzPk7HG79y5unPt9ub27uatrcburXc2thp37mxe
# DATA d4tDFm2y2JcCNPUp1d3euKO6jJUaTWgFJIoCSVxqH3kw8KS0p7ccGGl9ilMqGxC3meKulTZNZR5e6rPP4BGis4ExXUe4/5OFaYGW
# DATA tc8x66GJGQ/i3+Pq4988+x0a5+LIbz5aSQUDP2TuHnZG19DanayoY8kaKaOA8ViZEX8fPclwOxXotkM7HI72PuUvOjMkUIpRQ0nu
# DATA yZMrC9+B/qdhdv83qgqerv9ZeeXSmq//vbj66n/pf74r/e82ylFm7cXdFVNIgJpV7Vu8UQTqE+eW1W6pGxjmGWNzEHDKS2vyCxRB
# DATA 8nc/W0CQZ3Dq6Xb2xX4E7gRSZNiWv8AOqP/WWP/yZNQ+GcD9jiocD9WRtE9xV1Ir+G7AYb2gq6bUshzCTb5V6NaKrsekwT1szQMt
# DATA KEiC5vfW1Ru3rr1TNKnTAEGwRXnTWhD0y/lyKHmaZYAkqGXEGwSgZXrvZWGx8MagUGWnsblze+Otgg3W66D3SopCyL0RS0ZhrIqF
# DATA dHPr3fUbm9f5VIEYeBffxoO5JFgjaQjEYkbLPlvGqVIHeFs9LRQnUTjh5VdfLc7qkelJ4yacVlc3Gtu3N99d391wMK/xaOIJNblG
# DATA XvFzjWjPuQXHo5tWHv/rpLrBJ0wi0cJODgnLdwDfos8CLkVXfxAuxIxFELB8ItdK4CfInRYyJscbgu+Uu792dsntrikpPabgNAZy
# DATA 5xHIbxjE6vLaZcyNd/cu5k2xy0IoXn/YKhwUQR92ER7xTyWlr6y+SjFo9lfFeaZje31r4wZJUwuUih1dROysOhgmxh2BG0FzPOpH
# DATA PCRkMgmXxQeHwRulj+1kp7ng2SycLS6yl4LELmJoA7o9OPGKk2Dnmup4rl8gz0V8thTnWb8hc7W1/u765o31q8425nnLKPTSbpWz
# DATA ye+0RyPOIK/b51c617Nfm0YAR/ZgQ8Hp5iTvObOIAibuRniXYaeFscRpD/wGiw68N7ZBClG/t82TNnmjAi497GpIIezPtPQvlh4j
# DATA 3Vsv/6RZ/nuAqzZ/NirluuJfilAnKSn2zjXpWxu77926/U7O5BvyTFII6a0uLUmqdJPyCuD+mETR20p+2J5tejJ4gUDe3751G/1z
# DATA KQpce13aLkZW+/pPSI+A/bD3MYVZYtQx91FeYV3qPFVVyKlqWINsQ/Wmgjc3e71VZYgfgkHOms1AUSAFnAP1DH6Lbk5+C0qg/P7Z
# DATA uE0pT+DH4bB5hMKHLqyOXN0qouNSa/gSDn/FG5ZfhOW4A3upJmPR8bxMbdPqfnt3d3uHa7698X/c2by9cT11Th2tsx0asi5J1YrT
# DATA b9++dXUD2JgSs0hvIblh1WVifTw67g/5TlpN0qvqQq3YDMJC+de/99bf3Wisb2/SSaOuF+gJHS2lZ4KhCN8DKEJNwaSY4l7spT8q
# DATA q9vLg+aw1W7BX+jvlar9VFlW/7eSXomX3B72FbeuJ3pW4bbkaS2B1FFAg/Zo7M19XFG8oa/D39cItqgLMcslndItIw0qBL7TBQ2/
# DATA q+B/odxl0KqqG7mohli1hsr1rK31a4dtYBwz5oihYxX75IECkDW5KldTvPoqogRddLNbpW7QD9LCoWFLGq7074k9iemHgj+aB9AB
# DATA 0iuA2hWEvNoyYCSMe/ey2l4dXgAbpm4XaDj4Fi0yUv1+v3WqJhM+v1DD12zKutI5LMDT19cWMXUF/Kd45kzalUi/pGLVswn1pTKA
# DATA XINXx6CwrYB8XsDn6jI80dOMfmU1dCejhLZcXL09UHIwVVSsjPqk10JpTglzZrrIyfP990VTi79fqtXSPlqW0VJHhSp6Sb3S+oX1
# DATA WXTqrSEu6D3rVqFeTAQVPDk76Ko9KMSH9AhjnywUkLgLxdrrmpjF2F2jZUPOvtQcdJbIGL6kjeHFK2rgBe6/PBUfThgBq6aLkQFo
# DATA sIor0iwbwMNW80zl1req+qy2Phw2TyudDP/luPas+IYY1vnfCv+rvlWdf8n9COopxrprN6k+g3J7y/U3SCM+d4+X0gsYg9i+c3vz
# DATA mkQRSGWsXVcMp1goapWVWhdfX2XpksiZ0UI90zjFjwCWTGunoNSX5LNIwNOf0tOoZgoPh1KiyiDUGeRaoAQupAszDSAis439iHli
# DATA PN2XmjJfbVVbuQJcBv2X8MqgCuy3CxzCYO4BfIHhQ0fxFYoxLomDFYtE+Teo8JLBbdg3DHw07bDcXn9ro7F5E/4bylOUlZyv/pXd
# DATA Nlzsm8PT6xITUiCoCsgrKSnQkCJwyGW6gh/2u4pBO1jpEptEr4oc8ywqMQinMh1mwYxUoAhlnUbOg5otPpGONHL+YilHjRoT2Qu8
# DATA Ek7GmBcR3INUB2gLi1Sefxeh678vZfOfluhPBbluk/QvlkYFicukLqwjxk/7ADO/QihbmSGl0Z+6d7+oKXMPqqwL3hgUh/+iqOSh
# DATA jQQu99gyOC72UIywRqIuNGphhwU9EHNbKc7XecatLpcJkq9cHqjbB1512gzZZ6NwUS/yoSPy5gCfqwVFAkvNJPCWi86FOJVrn3Hb
# DATA u9xKp7mj//S9yPO2LFD9+rVrGzs7jTfVjgXxltK54T2d2A7oCQ3+CWZdyGM+3KJiWbfprFXfK37cboGO/T4mluc5Ie3jlSQ7bg7J
# DATA +yOh1BOKA51a6TKB+1ke65R8B24QCyapXhyYiJNVuUBE7BWvhO/Y5k+r1sjSyL5XBXDAkwXJIgF1mU4By8EMQllBQqeoGzYuK37L
# DATA 4yYwJAF2iFbUHx0D0HZOPW4uHb7LlxL8yKTrsCemAjUBzrlc8l/S+Rdlrhy0CewFI3QRNsdZikulJuNsMlnQOd9hQFUv3+Feal2E
# DATA 8cJwtrgorFgC7u27Mqe4kyQh+lPQNCwu0vJNIpdla+rEN9itmLAozlJ0mFJdF4JOYezqN/wzKSUB2ZSYZsxR6d8b1TO71/y+Qcmo
# DATA Zm9BdV6KHuImxO7e2dq5sw3qAX3XDDVBkIHFhpySt8T69UcYGBdT9pQMxK98apNFGFlFaVbgaCDpmUYKWh3UFMr2R5RMc4ADrKSj
# DATA 5YEO2XomfShZLcrLPYj3kpbNYUXPnQ68VPP4z5zTfe3W1ps3Nq/tRqbZnl0MaTtTZ9sIFB1dRSuUXpear8o31rw3R6MmcC/AWwgp
# DATA A/GTU67dS2xqzYNUwlPgjkxehv2cTItYszoGDrQFqBkveurbrLC3aNqESS4Wg92sh4BxYVzacRhBLBfiD3UnfxIy/AK+KYkPIIcI
# DATA Vhdc7qWJk1LhMGVavEWtBWS+Q3tVZf/SGlsO8Lu9lCIdIEmSZ1EgZHDyPkSlGX9APKGeIytSn6DNknyAe7seVMepFr8z/38O//zG
# DATA w4Cm239XV9deXfPsv6tr/+X//53Zf3dOewfq7t0DYyEEp5Cnjet5TJnIYQ817XwV5IJnQLVRvkKBD7OEPBxZ1l1+wvkOxRh7eNAb
# DATA deUHgPOpL+SnDgv+Rm3IcOF/EWvxOxs/BgXlzp2rje07VxWjb1y/dXN9cytdWN/Z2Xxr6+bG1i5GPqAgAkknhunfFd6okrvHXnJ3
# DATA VL9QfCP4HF8s1iqL34ds3O3KTbDoHXSbWZZcx+1IR405dTTcuJoXYoi9/vAEnJGYY+Xa+vjwta/hxBrZykdfJ68nr6yskl8lO2VB
# DATA bs+72d27P3jje3cfLi+X7z5cObz78NXDesosLLDi2V1PaaANVq3z8eiZEZhHW/YIehIaI6wA6Vyl/Jy2BEYFIXMBXFFKydraxah5
# DATA 4vwDhC9phLqSCumhCmmn1Wum+jwpVrqQBJJN087t3ImM5z8LUJ0THmyIwwJaAfoIj+15ew8qAaAJbAusvq+gNTet6KzZOD71CP5V
# DATA A2tRjiJwiYR8Y5he1fyFBj8vxxCoqLvdgpdEVu2Y5YfiDXvhffhL7ZsUMI2GoyJfJYa6B5YjZlA7Am2ELeyx3U+1xH+i1e/SykTe
# DATA FN+Yq70XoHrOFCi2qr1qeaUuZExpo2Qi0XKF1C/vZF264qoCy7K2TMtSSeVyBb/pCmgyEDnjX+KBr5d/ogZbafxDuX5BPVrynxUX
# DATA adohOdT5R8oCHFIJGUUshxtxqRlQ0Igjt9nJFLFxm5tFkiVKanENPQKMAJ7M02d1O1p/E67su2+nke33TbgB8R4FBJat/uhNgGrx
# DATA tip41/BMVGMOrNrJQY/lW/UvKpzfwWh5dY0Tndtve4ClBKuxEqZHNaXO7zu0uhq9mM23vpjHrTlq+j5D1hAuJCtFe7NB8aI7zBej
# DATA LV5PqE9thr/xJCLYHF3QH5JnirsdxFelogOegbHeS2d4q713W4jy2u2N9d1ZFFuy07vH6Kt5IYe+Im5pucSmSenrrWKgxkZZEmJo
# DATA Du5xmyV+BmNrbPxIDdf6vXU1UIlehW87vaPNW94Wzenfne3r67sbjat3dn7saDrlk9NOu9tivserba+teCUhZge4JGUFJMapjkma
# DATA NK2E8yYRB8Fyk64EActNoZxMU/nTvnVrt3FzfWv9La060vrCKamEbXZtklUHPNu8chi3acEpE8dmOw/FgPyFmYhjuI60GggQZZVx
# DATA sbMWbPZoK5igYgYLEqljJXmthqwDXxbh18qlPPHEq4sFdDi8I4ILHdDoqLRSWlm9rB2VXM8rbDbWoNUYjzev6/waO3/5BelF0j+f
# DATA mWWVLGJVEgTCF5ZYgLh2kwWDDId1TUweaewi5XvDztriL7JNu3oq4x8CWhyZwlg0zru1UfFQCEwqtiXlTq8TQ+CZPofXbt3cvrXj
# DATA qW0jnCW83UUzaRej6r5zNm/EIVjOPZgs0NfhMeZOkXlJvxd8U4Imzmjeg6jlBUeEJO7bLPHEoXIxg6KXPC9MSR5LII77YK8ea8rx
# DATA muV6oiBhfkt7+odbL0wKoYCg+12QQdquK0LPBfx2j5C16566F985+czxSWjloTWVJuqyI+SBIwhR5mslCV1cfTF+IAKQwW5k7smT
# DATA yVQklkLVB7zt02bTag3cuZ3MQx7zhWXkmjj/qJs2ShoMjETjLnrOeErdonOAcSX5rQjGHBfcU/c58CrhW2JNcbOV4t5K3XE+FxC5
# DATA vSpc/sBT8WVV7uX0ZYuOfjbuo2hABZftvCcteYwDKWDJkoispF3vdPWnUF4JtFXdBXaVhmjFZVavpDZbgXevJXitLGBNco2EH3Y6
# DATA 4vR7aXFuxuJeDu2Zo26uVFW79YjCQoqBMgonVZ2DqEv7niifMKIR39VWijj51lzbTlpMVpLKojCLDI2nC/bAkCPtmfDoqrvrG9Ko
# DATA GEJLTMO5Jgkrk7RcjsSjKtjBYf/owiKZN53W+Sgz9VXIHhlA3k5n2HSnhIzOllN9zAA7hZ9bfiWuaTZs6TAB7SsqoKHNatRNQuaB
# DATA yuypL+rGU8lOMeOc7/KVr0RdOOexzqQojZE2EfUaLDkftVEfyDruCqc7KC7E6YIT2DrkYbVG1Qk4gk6qIApGQJzYT0FXCxrTgtcm
# DATA kkeFqiB+IBxV8ByJL+ynJ50sQ38fZzOdpThYJcLxoNVFhUIX1SPu2XH7oTQgeRKpfKc1kX1o7A4ctkKYHjUMAWAkLbgJ8V0DL07m
# DATA tmDuqOGl2bmr5OxuDivQVzKTWISQzWrnYBQ2/6RBhHvfmkBqIdC52MIcVmKZq7P2iB/iNUmWAJ2kBgh5clvWYBLTttC3e2HpOlRH
# DATA Hdoz61ifX2J8e33rrY0YYzc7ShqnPlOOKe9ZSH2OuHvSbwGuXMvI/y/MTqexUi3oO+LsQp5jzBTm+IJSrdVZ+TpKSDMl3XMxaV8U
# DATA nsaLY/xY7o45InV+1/NPyvyxVAb9QUE174cKBVJz1NsvrA8PCpFDcsvrvGq+AxJVEnzHPgV4YWyNTwaZdnlr9zJwJmpmB50OKb5L
# DATA mPW6N6qtSn7hOdwWuQFk5jD/+2kaOCjEDlLcAy+5NwmSXrSgZ4nKbP+DxnKWMZf6uIN2ZeN9DMrB2oK1p13vFQcyU1NS04Y//nph
# DATA GiVpPvJCA+J+wz86DAdccnlp1D9Bp2KrBm5cUIU+kV+iG3PYqPA2fXd2vvNv/FJ6noNFp8gShaIkOmf9oLpDxnJmlGFgYCZH5/i1
# DATA QhFOc6cjVI+ruaNnX0+ly/VSegNQEdeW+68C7AildMhII5TjWGMSVZ00e51DkEI4hZXxMNxzuhfNSiUZh/ChyfrNOa8wIaGtB4me
# DATA W54fr8l05UliVkVFW2Saq5FJILBjb0v6mGv3xicIdloQojFTV/dSbI3QBdpSfITaddNAwRy6xXhDEZHVIp+YCRBXFujIGnd8g55H
# DATA FrEazZnPnDbilFWI0wQje3PtgUZhYXrtZjJnf8lLJWnVXL2lGDGaWXsD/4Q4wGANhTqG4IaeKbmZ6zzvUhEqk8W5qnmygjfz0w96
# DATA tOWOe6TqXzj/wR6b27kXxxhXLaaqrwGLzn3hfw1IcMf/76RzxPh+36gL4HT/v4srKxcv+fgvK6vL/+X/913873svLY2z4dJ+p7cE
# DATA QROD09Fxv3cRosRuDSDvfMKZUSF0tNkzcJkBLqkDHQlYnJ5XILvTNYdH6G+3oL0CB6fkjQeaDNi54oknvymQ9+/hNvi13QAD+BhI
# DATA WSBIMuDlN9sv0PYiXHjhzFRRKJpWm6ZUnWgmxp84Xbe5r9heiIRwjQGQjSrtBpZ0Yr5sqy1VpK3GFQpYkluh5GmpgFe2WsiG+pSA
# DATA FgSwDN7OXY31qbkLz/hUQiXMp4Et2dZBc3y/NcQaBP07YCTHzSHikaxqPBJ8YkOSqAdwJpp8ZHKllSG7N9x8e4BGb7BT4DjZb3g4
# DATA vm13Nh4Ft13Mb1wMTnMuMt1IyerEcBpstyi5U69twmwAUr9oMsWETc+nzIrYfQ4sZVrNUqtxl2o6ixcPtsb/lmIxd9o4X2N1HAZT
# DATA 3VE7swa70L7BFAUnR8Jpmt2OEpMys9H8oLOMIyox8PKFwVLosY6llXCKr7WdRQuLGYZQVy3+o5RtSKIdzF1nsSCjYcQQGrwYOyEW
# DATA yitxfWsHQFasIiEezjQsltLskb3NTrGcVtBAyZ6DP9BXdX37F9Uy5Vwjp3XHKdq51XwTLsi5oCdnHujJ5LsFPZnDkZCeFUzXS66z
# DATA MhNVybhKg0lwbe2iN+Ca8bvGqbq8XMy3nuiURTncgtaPEtqN+pSCuID/tUgKFGb31QwAo3Z3a4nDuKfj5pSi77EV6jmHO9RcQnK3
# DATA SCzgE4lSs04JmsixVBvjEEdc1JIzpz3VOYxOo33NwW4SZsvBB6rFN2/f2tptbGxdl2ds4r2P/YT87RO/Rz1uMuiTtpGBSNewogTR
# DATA /vDibHDBCzrM2jzfL8BRAW1eSWYYlF9w+knNfC+5jixDMNEy9v1qHgz7WZZghgId7K1D2EZ9BDw/QN9KTNLIlf0UYPjhlXzCsbaE
# DATA QaCeUxDMfhsEX/LlbBE+evNkv3M07o8zjsvlKNqMPZnhK9FQ2pMBAfL4Astbz2pMjxTwHr8cMyR/wYrFL1j1nHvN8v6H/UNq2iMn
# DATA Bv9g5ThjOVTJZmI6FVm3mJVFBx6bDS+0rGd3ysY6jKMSuK7XehTMQ/2RMPeJx4QG6m+zy9RyaeQr3QiwLgDNup+P3RVl3XpjOmNk
# DATA z1KBU88CTplZrLJGNmnC+29AGgDH717tlnF3ZJSAWZuAFVU3jZHaoNeRGY1bsTPpAS7oHILNJqYadKTOv0EwbV1V/0EPDX5YZWXI
# DATA harkUrNcp4SPxwfDSqe/1O2PwI96yYQLB3AwjpOLNQlEytDWjJUdtpUA0uF7lNupJepUeUV7/lTdsaAmTX+uRYSwk07Ic/h6Mpv6
# DATA oPL5z090GzM/fD2zWeKZdD9qn4CDWuwO60WQFwLwAcEjkHujfqAD5ymQHNoIjcPyBhYSWuDpBQL23QxBddpq4aHo7TIgflGrQm2O
# DATA xwN7Y1ApjGaudRX/aTWx4aqMaEr3i9oLnKBCINhYid2Q8BKlkZqFu6F++ntSPSrsLVof1ckQVqPY8YPmALKINfrj0WAsD0eEO1Vb
# DATA ubysmSaPk4YFilAzQVaOUY7xJ/HXuVNA05atDWhYcjAl6QBvkYyRCX+OUf5lIJRs1KefCIciYCgI8TIBuwtDp1jeppR4Bn2/sNeU
# DATA phHjnSwgnnYzI+D+gpvwKIX8buOD48S6MUBmyOcfPHsMOEnJs6+ef/T8Q0wnCdknHz//GJJDJs8eS2rJ1IOaBxf6ez3FKpLDbhNH
# DATA zAhOH2JKX5Y6+GOBfkJgpk+x2f949hTgm6gVLyNl2BZkCgH3mz7AnvQ67RY2aMFDJc8+U9//BfNc/jOAmId1XGv2GGIUQIxExuGO
# DATA tprtEzSPpfwA4axs/KknsTqZRzTZ1clS9eD3n2MO5A8wA+dHgHalZiae+FO9iEx00VtZTY1olwVipAyFRP9kyCAKUGRJr/R1uNMT
# DATA IpJHQGgMx2WDb8kEPM3r6q8Sm3SePUr9ZKFyoQjTzRYO02f/Qqmg1XR8+uyRtFY401tuUmRy+QwRvqBjv8CU0Y8AGL9Evfo0OQu2
# DATA 76QKD2H8k0pi56OW1PSP1T+P8WNABoPMp88/cp1xzeZSzMJwKXQSAYZTIIweVLHYrllBLEgIKeM5a8WCQsDQG2rwsD5Trtk7OHZv
# DATA jDzbsLoFmN5HmD4WUmz/cTY6Wg6hOyq0Pd9fZuB0SeKeXe5IejAMWsO5cANIinV7FnRR0aFJaCO8KBQdU12gXnOH/9+d/Ld/0hzo
# DATA a00EU4eGtColMhxGs6J9X2YVTlTv6Z2KHiuxKjFEQwp0o4dVxx2k68bpQKAnmQ6CuByiK+teWj7kL+FdsV4XrBC2XlCcUoOsgQyN
# DATA hcpCfkQG3gZ5Iep02JzrNHY+q8a67fagRsjc8KdBsbI3iTE8xLIsQCSd+bWQC1Rtes8biWQtDlOyK78pFjwTrxSGaMEOCzYrSk9c
# DATA Vq+YKakfVR2Jz6fxqcFTmDqlFjKX4kJekI0rLRHBMARaukgkKcJHudzrl1E1MMB0BfoZQIQhH8J8rvT4EFwT8cxiDxFYYRC7fGOF
# DATA J8YteL55jmu2F3qDd53cPftbtVP/wJuTDkl3t0YSmswjsCzYmPjIRQ2ZFyuU6wBOUxcNfxbEvOMVCxa7SktRPPzBXm1FX2UeAVDj
# DATA P+tO0T1OOV+XK5XzFl390v1xpwvCj3H3M1+fEw7M1eD5gGCzIdpMw6Sllja9iruO0h5q7vQr+lonKuwyZBtT9UdugZMFx30LF9Li
# DATA UcXQcwvhLUE3LWZTzDwoltPKeHSAS34ITwrpD378g5MftHZ/8PYPbv5g5yfk2xb1+tqrXmZF0zlcsxDxIRGPMHDIoihU3Gs0j+xS
# DATA QbNHAoYVxBqdk1LiQOtXZRNCVLIdzFlNNKlNFkKPEOxcSfeguDDNkYz6TaQvzmTzfSnmCvdb+sX8TrQ2zkzpp9ZsuW1YyfPszfeg
# DATA mTWGBM+pKjQqMMH1tHIl6It5A0MVPCZLt7hyuUkXtHL5Z+MOps/V8y3M0g9qsus1jM90IMLYHcRMc3O0a7KYs61RccfrIIzmwpZy
# DATA QAZbJ3r3CUTM+JRbSSRM/7Ube6tkpTywcGFFyA12KZv7bXxL1ho0qp7zst0ZG3I2xMq0u+OhZeb4ReYQjOtGZarNs55E8GFjJhBL
# DATA 1JcaqwthermKgz4cGRQpKzX4ME+cpQGp5utSzElOhhCa2upMv1FrvN7G1ZVEQEICWp4hKge6ohxBOKIlM3KuycJZnykYyQaWqQnm
# DATA AUbQGTW408IiLbqhKQpF42JsZW18Pm/e0HKgSt2PyoElV+rFbhSDW5Su6HvJzqg/GCAM2ZFAvWb0qJKsJ8IdMFNVJ1N95vStaLpR
# DATA l90EUWHFX0nN4EO0sV6/WgnWljqtVVooWLbawirVDxFSIji/i4oyyi2K0LW5Fioy9+hzdGmBG1LIZW01p/V56NjZQGUIRNUULi0X
# DATA 4xHREbavh/aCjN9p4hvl9f6ZQjN2FsY3HbebXQyPnn4MvI3F7CdQZJzF/YXnO1LIUscdAH0o8a2Unpz6Cvu8+vPsI+gRTTYVAGTL
# DATA 58sBRzYSLNaBXHW21yzfTv5Vqy7hnsHKS0SvBy3Cl6A9I/XSV3yJ+Qx1Z3MlbJyhk0jjxsB9tXXvxZZJ1r6m9mZPZh0j3qaun6w8
# DATA 6bBb6mJE2mjFh1p5i+ZN0u9n3tcM+P/zX4AyL7FVj88+f/5x8uyPcKnDRwz2H50B1DAUVueBM4/ohj5Cteyfn30F6kDQzH4BOtmv
# DATA UB/9KQ/g1+damZyr/xzsO34GN7rNU0iRQdqPb15pwZxjcVGEd3NEv8mRIbEhTVyJKRQdbLUS/u04vuQ44ksVjPWqj106ZOc/Ug3s
# DATA rRsV48nz/4knFrnTkyYO7m4FjWk1zDA1j3gDV9aHR2NgZ9v4piBWRDX2WqOhjo1Go2h9CTa8RpM/KaRajU44+qBvqAGZZAd9RtrP
# DATA lLgiJilUCIocQWrFdrdFakSKiyLxie2e8IvMamTEYtUSgcmgvUsM2chiUx1BVIY7APyUpCto2kWxCQ1gmOFkPOzaKrXo8Mp4M8de
# DATA TpmEchnjUiC87nTQrumMXGixq8k3+A98lZlrG/yqWNY/xUn13OXJzPQNTkvJ9j9wOAAWIq8qdZp70h2+tMzLrmMCUrTcU+J95DW1
# DATA 5HBaep8P4ae0XI4shc9xznQEImvjl8HB1Xr9Gvq+cvW+e0ZwcPoWMDoov0QLkGL75+KzUW0wDchwG10wVxUMkhH1fs8Mqz5taTm7
# DATA oc3TnNNG9Op2YaqaLnT4N9/k8G9Hw45P9F0Cf2ldu9aiG+ppqF0C9nO1aA00LDQaSAGNBjCVRiON+HYSu8l1Q9SpL95pn85OfAF6
# DATA +rYHrzoEP5702b///+1963Nb13VvPvOvOJbrewAJAB+i5AQK6lAkLLORSJak7LggggGBQxIxCKA4oCRG4p3YaW7bSSaddu6nO9N2
# DATA eu+d+1lx4kS2Y+dfoP6j7vXYz7PPwQFJuUmu2MYCDvbZz7XXXns9fguP8s/o9M5pcbHMfGC4vRN4bJKs0y2R5ZGTAGHeajjRv375
# DATA T9AIVEYWSzjkP4faof1KICjxOfcGMg9h05/iux+jqQxlOCEToEhXCsRrH1MmI1BG/72RlBt79gJoF41F2CZAvMJtswbxD2SVN0jx
# DATA lHIOFRb/PCKk/rz/LJU/3qOvHP49O/5rcWF5eTmB/750c/F1/Nd/bfzXtoZ5x0Qd0ZgQOEi7n4j/iu+Is1Pw8v3eBFJxSScHFkbj
# DATA fDFgSdR4mT2xxf4JfqT4i0eEYfbFP/r4sJnMyNhHf1ynxuLXqjeV2K1kOO+ZQl3J8oJncb4HgBW9ySkZcKsW5LMd414I9xbCyo+G
# DATA 4EAP0dNwz/pI+rSTR7up9QwNhyJpdy0WNbKRFSffqC4tNxWudGc4BgRVDQOEQejao5XSuhlwCApfNWFtikMpHdNLmQCkZkYYxjXY
# DATA rt9b39nd/jC08Z1MZCeq97A/3C+E1yW2q+WZLD1CPA3P0rjhMWDJkXbwuGwPkk2i0smzwHnS5t6D9lc3t9eSCZmhpkwoWrVmSUdM
# DATA cpf3LJ0BjTunxgGPtCuNdLJXzz0T6pW0jYiQJOauSTNbpKuTDU0H3U2M1JtRnFyBH7cfRWWvPZTgOqAgAO3zFvN28KFgT5AnqIl2
# DATA btj+7QHhdcFN6yzPGPV94lIDzb6pcG6IQe9vEULKwHpFCoZAAKjMuIhgUTNvkU24ZEaxUCzpFT+MpUnTu5ubAF/5IRL1ju0WRXXI
# DATA uF2+LdsYZHiEtrtl9DHXLtbDg4B8SMkscYymC+beMgxF3EejJ+2OpFiZtI7YsAMInrURFNG3HOcyZEfmcx9v4zDDM6Pt9F1ig4Ua
# DATA pT3UoZufCmGd1h3rrid5A9sUYC8Z1Vs7KtGs6VJQMjZcWDxL8C982RudYdgket3YMK5YNo8UA4uMfyjaAQoDQckxpd64LcOZPXns
# DATA 2+UDCBp+urhUur18FvodE6GmvCx8dXNjd2V9o74NmJ31jd1N+yBRhDyLjec6dIBc+MX0kBpR6x/EfAwfE7abXoD5FI6HwaC94Xxm
# DATA QZ/6XsWKTGlilpCSs2RULMobyKwsrmXEW6QYYfTpOEOwjCcsBrz0aUINDY+MIzAIVavLjKXIFePjhQcyqqxAbjtBDMm4pIaqrmnG
# DATA cDp2DY++RqppijmAns155x4lzyNyLVMB46EPTc47RnZiTPF4nvPB2aCHCTspwD8s5sdnXmBBvWk9Fgm/YcpMmeLEJntwrJM5VLLR
# DATA eDg1njhsVBYa7yglGmmD7CHXsR0eakq0otfJmmYqZRyJVKKp9tXE0aYgHTDPDgCZxFlDTxWvUcZ1gMuctodxReZCDQemjjoJQYh5
# DATA WVjybk8KxSysxLwpUwq+nClmrCnNDPnew+NE+cWFhYViMRs+MXuCNj8QR4g/V7LP+zdHbuJiTpB3YnYNWw5sWq6GHKYrBAJ0CDtz
# DATA pQyqYm5qsuRc2mOfDDM3d79+b2WVZEtKc77zis+/vEegxFBgcwwG6qKYagEp8FBSssvpzK45TqvkTEiA4JPRCC/LUzqR1lPaCqk9
# DATA tAFrp/Z01nDTosKiOIwMZU1rHAmxD+4K0nOjKt0RpU9HtgdeMSnda7wA5b42BaIgPfDfcW1TJmiM9gJrN56ZWW1pzxMDDiEjU12O
# DATA CGelwGqZtkbCjJYSBYc3a3gZMwzDcCRKS4uWA4HHRWXKKUhrn0gd5KRSFduhTsVkohxPAXWk5VFFucfVZS8or/hycpGLyVVfStxQ
# DATA +APtTmQJ88ZGIZc60+VovWtgWKUBP3mmSFSVA2PAJmf97Q2nF354Hi0LJP2HpnVP7QFqudc18bj0r8V8kepeHp/PNe4CEekmB3UU
# DATA k3hY2PszRcaHOXY2ZZ6uTLtxJG4bM9w08t8yLD/vRjIfzYy3j+TNA+bU+OrwM8orQLcJP+D2Ra4SelBayzguTL1cOPfOHFeLS14r
# DATA LnSlyHudyHmVuLprRObl4AruGLPfL1LcEjV5zOW8ieS/hXhQQkwkCX3lwPwXrm5a+5mJHwUrTRPcwTUv6sarShxDVeYUufLsaiEs
# DATA Smp6ZZc1qgXJZ5ErkqlY22RILQmuuvumtKY1U7nkPgdnhOUT6a6F+UezxAukpgfr97ZXdtc3N1o7mw+3V+uhFWgrnac4/GhEEDea
# DATA qYu11eXpkbteJrcfQZoNgoWyjJZ4ukHlWo/OJW2zID9MUPobtRxcO2UCcDup9G8P1ncerOyuvpe0IIJundsXfBmJmw4Y6RFGq0OI
# DATA sPlX331QMpYe2qglIFmgBXlPRE9Atr7ItlEH2tKmGQvrKJnRjV4yU6OnCEJLKAXhKuURWulWu2bT05RVJ+VlrHMYuGOpJmQcxwKV
# DATA XefU3QCJ28iIXN+ur4XpuKV5Lk0uEk6eWdupb7+/rnbhmyhQxIE4/9HsVSZkKGn5otM8hjg4MQXB/nj4OEbl9ehkElfmEpJNwxNY
# DATA dd23cZqJdJI+Dev0zNQXMOG7AkHKWSW1MOKBzJnHAM0tIZMDEdCWSCKtpoF4GBdNPZKcyLY6416D9xP2lAUr+Z0gW8wNwLkC5pKS
# DATA ShquiDHJNSdnrOv5D6B59KVpHg/cV0zrnEWRKw/urt97uPlwh5Zkd2X7Xn03nC1HoDF2nShwQQbCJ3iXk2sLBQeqIsQIwqonglB5
# DATA AmgrEj/Cu9+Z8pE5AUFYiALc3uDkeF+pM9BijXwkYGA0xmCD1u8oWBGJCD6KxoCjECOmECKO4abEIDvQGCmzNXgcYbZtJZJjD7jt
# DATA 3FqJPxFlhGUJvApthLGtEnZFozFm8rni1WCGTFC2ipBVJaD2pDMySsGq7UO+zMGhhu3dEssn7t+4t2BxoUdcCDrFH2OGDrYMc6Kx
# DATA ki4A3l+60xnglNCiCQHK2UWaEvCzd3AQoXpmfUvXfgzxoADWGbSxn5VgA08IIc4BHbcHhrsi5AiNAK7QyyQcGdLZ31r7ktjeU1Hx
# DATA DA1EegPT1AdSILVuF8xF+Ix0hA7jR/TwrKmSSdFBFzN7aLyaysO4gqfK55F1Asrh0dl8utZEJBYmvUvGxaVd86cCUikdwHStx9nV
# DATA CNBvBruCT6oFgQ1GTj6Sr8rlg/PqUYSsdxwf9UaAWDsguCN50eoy/mTCsuQ7LcxZ9Z4ZuoDv5MiJ9ZU0HngyvEOYRxvCjVuTIVKL
# DATA QQo5zQR6U1wAaXQuBcdT2X7Y2FNxrT8q+bs/JX1aQvsa+WkZT4Zjx1ap+vLGjPYltypHztaI4OkgoymehcViFq/zCqLMMCV1FyG7
# DATA 8AW864jyPJD704Dx+aENs5PMbGZmlSAKpsdm8Co9KtA/lB2VemXmSrZDpvL4EwNkD/JpyBtF3r6mb+IlxD09CinmSUc4w3XXPKOk
# DATA JJJcyywUAPce56K/MNAktZKxbXNaQS5lauNGLwBCQCAzbAGnq5Tp1OlahqSHefJwTV56Epf0RJpSKc3C88QWSkbBk1+t4fpqXLpS
# DATA +kCv+BrWYph0jiihSdbjyzvtyJdeooazWcK4oZEiLGK14Xq5Hi/2jCHhJl5C1Zrh5JkO/ICpdXVBfgweIjLzsT16PnO8PZp+8kz1
# DATA J8nlRaJHWVIdCk8G7UftXr+9TxgwYZo++kquk+lqauoXJk+kDoYcOy4e7Q+HfdM/XV1JMuqj4OoqjbNRFRe8puO/jrXqbuqfsqrV
# DATA /j+pZH/mAUlVt+h295QRaxTI8pKEXAEsCc65i0fE8VDwu+Gg18Gs3FyeILuOANAyUei7qgofiJZ/u8y8VWw/f/t26Hj2b0do4NW/
# DATA JzdMUUsbY10aCMkG1ki8n7EzoTYHTMULjZ8yJKueZD/sfZ/RDRtYJIsdayxQidSRqV5dWftQ+QjxqWopsFW0u9ZZ6wB4LdwhDIMJ
# DATA rx0ZjyQ36w/FdTq/vnpzq07WEFttnU/PrsEorB7L3qb0iOKpsyQTAKWwhRNHImnaDSJGALUngSuwUaxAHPYo3iwuLChAjM6wPxx7
# DATA qjXtxAbJZfVV9YKxNBT4hqePcsGkzqeYFLWSs/lGjVfcFLQkV5JUpYIuzFPaUPVNxI2FNH2gwZOrq8BN0Wg7gVAUQFfsTUQ5VgcC
# DATA UhaYEKMRaHwwc6lU9k2TD/5oMWBt6FeNYepDdTWNKp4rlyw81c7CZg7QFuysb9yT8K2ouVf6PpMUWd21iXGMYLnqtvtgJGLxE0yD
# DATA iCiJ68RhLXElkFrdyVF7YugVYOm5RowZBSoglcQhqMJQzzB5PCxLgtAZHaWtpS2T4SBJVBjXsts9RajmVF0B3JVWZTESVUSvWoTA
# DATA VgMQTPFbKOVVWgFrSBTKpi7ldnChIQLQcROpDPcx8vOnCcs2t2i7yqB7k+ylJ5zQ+k2rAmjbOGKTeaUW+4k2Ws29hIqrYfB0b0C7
# DATA GbPz8pwk7pPVmwuLC3uDMzPr+PFQXEopuRINtsHDalJXHgnyP7bmDjckKO45QZHpK1vCbH3syksVALAMn4igYw1TExBxecbIwTcI
# DATA s5AnzK4VyZ3rnY8mnXksN68JhFR0QA40xKKZIkZRjf4Mris0LHsJNfwxBhML3lWTaYChcbkumt2qGuWSXwmRaUrgnS6Fcy6ggXnA
# DATA jtHWKeUkY5Dtkd8ykVkENcQtSnd+VnSyZPGb1mUGcyO1j6U3lMm4PNm7UzjYeys7rbX6Vn1jrb6xK/mZ1ObkgIxOy1BPuemNqMGy
# DATA H+3Yn6V+BqxidVedAYbYhRtu6ihVXC69VFVD+1vnYxRyhJ20+wzeRcc5QFcK7j0Ud05xgbvDHkvylAzEDJn+6m/aGTwCliCCY8hU
# DATA RsqVGK4BgpG3B4ExiXgOa6Wx4hPQ6ybeAA+U01TDyENkrgPMOlTTTK1GCjRQSzgYhrMjLGvUoezX8pefDsec+qYNyGwjwtG5mxqS
# DATA m08NeIHYXnL4b/db1AE3ItfoVpEsOOq78lB08iipGlWgfUqIrw7vzapO31efAlVUzdhc3mc6KBdKnBV9++eM/cEA1LRrwVr/1yPw
# DATA ppJIbkRezY4xl6ADdVIwwJX8mGMObG/K7sggZQnri0lDQ5XBO2qxo5YLLKjWQcVqkOdXtz2JEkTo7Y7Pn8zkuxqPkWtNGOMSi+7V
# DATA Yienn+/H1xNH4Yz1UPoqvD5gyHiyQj65c1C8mW7NQ/3FXIbH7fqDTXF3R63C6ubGu+vbD+oO+Ia9uauO6zjtd/uMtt9wlKAHfjnI
# DATA 5x2O2SoTSBlNaysr+VXaNjnNZSYEhdsj9TKK39IQLp9y7szDKKWPZFzP2ZTROc0aiun4pEZ5yXKKmYlVnOlL+DOnbA1vrKzKGmsJ
# DATA LYBp6dynQiEXj9vqQTE1rpZr9JBSsu+QvRZkCSRsk8KNn8EglBRym95ZB71HFjEnD3J9VLHXaRqUq3FGlgyuZAJXEFiKAvhELbc8
# DATA B6S+mNX7HthXCNohBurn5tPgYL172WQhs0zFlP3tyhcztGLNo1OPi1+cIpp4mjBKnQzoop2I3aDLjI1ewIFECYOXN5Iqc5Q8Us43
# DATA gVYHx0ad7nPlj8SYqtiaHbk3MyTDRPXNRvSFmXRRfM1QAk31yiICusRuTqdTefQbnLKaSPulGGNVvm1DI6WBcWiJOKc0bntNuXK5
# DATA ItFLIoCZPv9JUb1ot8OKJhPuXnq9y2qMOAAfwo6CvLLKmEoLLa+brqGULcqMOk5byxJzaq1Q3mrHMTuOSoJgsEC88HTEd5hp8R31
# DATA OYgn2JHGgVgsg86mrdTJGf7JiZjahEdOLr+M4qwL67pmy2xbbHO1gjvy7QoZ/x2Yrsyi2xD9HbqhIOQ4Nnik6cQ6YvgXax7gGUWE
# DATA QfxV3PtxFPxlcPvWrZu3Z/FGr2+8b8hC2ikVPDl6oIjuF8bhDz1h4LWCERpQbt7Yq2R/L/4FJVzJ0tdBLEnlQQIxSTls1iyHTXOZ
# DATA HAdN+/CijGlE1zIf2OrDnd3WzsO7O6vb61sYIrRdf7hT57GBOoSqFoxjb6AsepcLhyG7pxMCY8azc1ySJbPbxYtaKpaPkumd/2TN
# DATA NDlUi7SM/lx0XrtKlo2dISY0kKZ5gcmcaGt3oqXCMNG7AeNFGcNFFxIdasfevq7PHwW/Xi6KOt8tMyVALmVukogc3JmG7EizwR1o
# DATA OhCU9k6wwqByImlMGYm4I2/UV3kj//XDdR3h5M8IltolSEWcY9kTrk+S5YjjMhpPWswpWswW4mRcLRF76RKp8lxbRLqcmFBuu1vl
# DATA LPlykqE1eEWaRqIbZd92XaHkfDykiXifasMl8wCvJ1Mue97jpV7b/GBDkO1avXX3/ubq9+trYrYEnwZRE2sF728wfOIXxyrjz0yp
# DATA f0/LTZlCMUm60Enh5NHkvucpmpmAjpi4LsxsrJiefm0mPzaUJXjw5G1Lj0vuUFQ3jfxtfDxcJONdWu2+vId0L+NBofUvXxanPNao
# DATA PyILVPbuzrGJX4VN5uI2lpmtOVk2mVeU8u9NOEkoX2cciVUUH/qnd/DKYgTDyFiOOILoYvp12O9DewGZwytzf/IWC5895uosYVdv
# DATA 27qgbe1qLGHW8X/llpvk0Xv9euFp6BpyJM7ztNMJWWZSqNEXBnAtmGYPyp8K8uKWowtoxTPtPK88SZbXpW9aVkfTpW8268vsVp3L
# DATA GBtyq9yTKesylMfJgICk+tuy9ti/ZZmPuHJlFsJ68r+eZuqaacJTDGQGGPolTD8XM4LINHzcipMvODOp3VVYNy6a8O61ZSTDMvJN
# DATA ZwNMZXRmMkCiq5OxrR9zBH0duZaCQUmlUtFnOHhA+ja4OraC21xRR88ZTtM+zXfyRoJQBkrDRw6dNXKpGD45rYUSliOcjruRE2yD
# DATA URV8iApzV3VnzDX1HNBnqeFtEJQcMbPAiO15qLQHnaPheLoL4tr6dn0V8BfQA6L+YGv3Qx0F2JPB7TNo4i2bgpLqJCCCMRgh8iO8
# DATA WdGAFMV2LtFn1PSDy6mK8FCkozxI8wVybG/+wKiUSNIIzpaRtv6wV7svNe2TLUfq1pc20M0HK+sJRRtaXfPjj5IeuNef0D2pD5G/
# DATA NVFBhdGQ5cWTVxF18nJFZZQq2oOMJWLYzOQtjLyksTv9+Kp7kblyEjtArNxfCepo1X+wvrO7Eya2IqlumNWkq16I/Vl6l96BNfwk
# DATA lZv+qis6ImQcMU8M2uPOUe9RxDdbrgudRoPhoBPdkdndDXXam8HJAMP+I91iD3KetAccRRCBKYDSnuyPYdtrF1VuL00lozo2o4Ow
# DATA UXUuHU2CLWSH+DtPgO2ZwAeeai6KC+XiLOA5ISdtXl7hTyxXJl0+e+glApNqDT8yZkK/3DkSLxbwvWIGgrWViEwU4aND9HXUb3ci
# DATA L0h17WgyGVXnNUx59eYCBWr5CsMyy21QGWuQW58OKWlfLZn9tuBUntrRp0ZsXRX8ggTNx2XwKhxFFFooxFRUn1SDhuXMoJoqOor3
# DATA cISoNqL8Qbi49HZlQfzfYvUpPD3DAA9XU09MB9546kAdkLhVHg/7ac4Rbk3Dw0MKy30adsc9zPVLJray1AENR1J/+DQ8bj8pg+EY
# DATA Ci0uHJMO8kmZxxveDM/cBihisnMUdT7CGiZi7mCo4eqDNZQuBdUhT8X/HkSAA3CN111PBszCPJoKhaw8T3VeK1YE9xkUxrW/lMHS
# DATA mG90XBl+9M5CdbFYrHQQVqBQdEqInzjuX1QoJBro+i1k8hyWqx8I3gZcSjxYXKJQyvGkNYrGvSH4gYVLC7EYctrhCjPekIslrnFT
# DATA YSngakcfbfvqUxminXCBoWVJrjPFduuu8XHg9o0fS1d/BhBQeakttQlZT603nqo3RC/O1FvQJcj9AoulveV4CFyB7porW6Qpa62N
# DATA pKOCpJh9saipYmKAhnlYxk1ZTIAeVpeEdDLqDaIwBz+QbAUn5t7mWv3uw3tQ+FjMXA+ubJPOqLYQ4gRKVhB+e6H6beR1y8s3q+J/
# DATA xsf5k+4ICViGcvlYjZ4hdGaq+kKqquOhEifLEL9ZnYf/6mc0KdV5VgFbbtc0XbILNEm6JkkRZj347GwaOyY5qizlKHFPcDX7r8Zv
# DATA zGFctmNsFVFACkkicdAFXPf15Lp4hle0sBbow9kl8GVSXdlMZVqmHjRV5Z9DedqdrkyQ9zJbrenVQeU2h525ITkEiWljoTFMMSYF
# DATA r/IhP44RDUdmo62sjA9PYLdu4S8FidkGuoJWS6xeq1U03qwI+m61+ZVCqEKzgWYJLrjWCJUqvazxiwldBP3SQ8KgmfB9h5UY2vRy
# DATA Mo4USy6fjPv8C18EyoCojYcXSFTq2FaOgHhLEfTCuAd4iSxztCUyr5M4KgPf0d+oJhKL3GB9eQr6wAaaGTNTLgP5itIQPlrbQu2X
# DATA 9NwwBEvTO9z2fAlRmEfIu9RMsdYU2fOhRyzH2ju282dSVU+wTjao0ODIdmKiFPgHCBKo9pmFxPVozcey+A+UjjVUEqa2t1EAvJTi
# DATA wiOgu1X35HgUF7zI2FgvKTfwowHEjd9NPhkNYkFerXbc6fUYG5nF+H5WD6PQ0vmivR0Lk35NrAD6MOnn5FGKUb+XdM8x4VJN+1Ut
# DATA cHpQshVd4ESISiu3P0W1FupVx3inp14inE+bYr4q4GdlnKOXUr39PIOasha4rTOoQyJXqd5eZMFdnpHRnos67M6SoWqj+Wa9yAV6
# DATA ZbCtjA4ZQLduX+DhxRvWHNJE3vC7TuecBf5mEGZmPyR3d0cv1daztWpsGtS/ul0xnHCVFsuYSFB2hHhV9dA/y+dQJNSNU4C+oRHP
# DATA Hq48FI2Uv6zrTywseht2827E7Gb1AVx1RF+wWmQ3PTsjmtYV68RPoL8rL96UbhXT98nTj6JTdiDCYCwrZMx72BbPLrB39PGcRPxJ
# DATA mCSSo1DTKa0TjYVmdoOGCJB2rTTIXTp8X8VqafHLHaqG40lbJ1mzaSSX0FDZJKfBooSoKzrWQotRq4VdarVgH7Za3CNY47h3ODhB
# DATA RMACfGz3Kzvr93br2w9Kgf7+3sMtM0M6Pad/ClRBKeAcItdb4iZ2qtUsSdcXkr3nLuz3SeLCzinkp69DK9qLE5Qrw0fRaBwd9J5k
# DATA uH7aGLNWflmFxpcro6One+IqHGMqbxemOF2qET06/5fg/A8vf3L+2flvz78S//08ePnxy0/Eg+fi64uX/+P8swCev/xEFDv/+vw3
# DATA 51+cf/nyly//XhSF3/8pOP8CfnmOL395/qISnP8fUea5qO7Fy0/g7efnv4H6X35slQvg/6HhF+efnj8XJb96+XNo/O9Ekc/PvwxW
# DATA ttbL4unXoi5o6fkd6NdPX/4jVCSefyo+/1J8ey564HT4OXZY1H/+u/Pf48tYQcW9ZZP6dmV1tb6z03p3Zf0+T8i/i7q+Fp36TPz7
# DATA BdSWa9zc6B/w5c9FeWo0MKt7+Quckfd2d7d2ynpeSoEo/jWO4qeiyq/48y/Ec3rtY9HgL/2z9xxmLzAnypmOlz+XA/iD+PqxKAVL
# DATA 9K9i4qgYdPYL1X1rzl7+PDFnGHHSelfMVesBBKXcBVvR+vsru3Wcuv+bsng4QNHv38JXuexfwQyIh0B5z2G8ZGDBwUEn8JExyIXb
# DATA Cwui6/9bVitnHL8/Fx0XI050WNoidcexow6Jfn3+q5c/F2tLNDgLWQbYPZw0nMzfc69+heP9THxcvB18v3c3tWM6LaanX2lb51fi
# DATA w++gnz8V5V6U8Fds/ksgzBfy+3OeRiTAagCq7bg6z+6G0ZP28aiPjoCJziGFctcsZvE/qQXRK0GqvwbisXuGjX0mZvOn2PDHojDW
# DATA JdaNX/2Sl+vLl78ASncrQBr9A47kF+e/E9V8jjPRPpkMzV6epTNlyQbRe0pzaCE/nP+bqBmW6bngEi8SjMOzU3gxf4cUCDvxHzK2
# DATA tfj4z8H5b8Wa/ARp+0tciS9Eqa8E+bw4/zX+Qm3/EtiZqOsLXF5JZYKr/VxUKboAv4rfBFF+UoFD41t/xn+TvhAlTl9tGwvi7/by
# DATA Mv4r/px/l5aWF2/LZ/z87cWl298KFr6JCTgBDZZo8lv/f/5du3ZtNRpPKBQ3CtjNB4RZziuqzcekooseB9vSliVdpSjQAIN2e8d4
# DATA LZRKVfmdKiKVmHwG1xD5eRjPYSQOGEX6vf2AH4OMLouMVWVaMlNPTtVHwYlGIKbPUYUsZMoK6UpaskxDLXoYlwK8GLCuWEjUgzju
# DATA F66DfF1CkEsOyzxo9/pw/WFeVwvFgf4ZsBrBMn6CbEWylK26kKeBgQnW9eLl3zHTAo7HLIfFGjhzkf9+DQXFAUOSjyUKvUCeJZr4
# DATA BKoSpb7AE/J56CKTG3KrGHyhEfJIwJMPxgKJ/CA1Vg2GJO487dEERjM8mcBDstkpVONbhuMI4kiTer0z7GZlEXNmyIOkXCGMI+kO
# DATA qCmwNWr3xoWjYTxhOAf9U4mSx5hLF9dC5VFH/kvyTTZbiLfBu6v3iGJs8M5nVFlkrYeo2EBMx2uR9aodYw1uYB3EyxMH3IiAq/B7
# DATA uDfYG+8thFM1nST3o/wARMInnRTTxMkcoEwEMhhIpSyFiSMcxe4XL38GxABy2qf4iqCSZJ7hkYEkAKNKhoAvLiwtB9fxn6kd/o8k
# DATA 7fEJyxSsOg8nuey8GFtZSm8oEL0wJTRxdP8DyGjBg95dleptW1y80ZcoiIcuO4Klj/72BBxMwL0anFBPYsYslSi2YEIAGqooAmgR
# DATA oYs1xk/gByme0g1//xT05kW10NZTCgdhPhA+ubXwHbRpDYbgKQCf0LshGqBl4tu3l9FFBRmFalaOalPUsrNzX8ZrxEEXMxYhpmUv
# DATA xph08LaZMG76HbFNQNsiFnLw42g8lKj2FJ7B5WnHqoRF+2F3GMUU325um1C6Ek4dCewd8U1vPnss2egivr8kp/SSEQhevwG2CFTk
# DATA iLi/hr0AtEUXo+fZzo9XUb/iAzAPuMs9Z0XB4kJ6ztCkYP0mw15ts8lVrtXl12mGtbKvknCdAEGZrmtwY/wUTiljRgU3EE+e403i
# DATA eULEz8Epv5FecEIhkiXiPpEAiA9gV7PkB/5OR+SPpZ3ozQDWSYbhx8H+cHIUbO+s4Iatr67trNwRBxSnSDkGJzv89XjYPen3EDPF
# DATA YFejk/1+rwOItgkiED8JNmbRg4/fMDPz1DSSr4ufJD2N2pDqgqyocVyVdUp+qV12jc69UXMaydyV/5640utzA44DsQxfC9nnExR2
# DATA PpEqJtR7+YSelz+Vnoxg9fROlN4taKDukrHdmatKNwJBppBIZSPqqmAxWOTWZNiKRcFBNy5ggzI5VI2SQy02IfWgJIzKYPi4IGmj
# DATA cjLpFCvwTfTieFSYwrtQ3vsiQPXV5zQLfFP2CX5w5f1HuPR+RVrC5y//Hm/24tpvZ8HxnIEqDGN0Ol3gMgxIabKXPlYvJsbxckZg
# DATA EZIYEk5YxHwIdcQKD8conBvB5/x/0dShyPRr7FTsyF7IUZTsZQhZSmMiJvhjQcNfonLh8zDRdY9Xrc+P1ngh4UkLcwZ0XQghR1Ln
# DATA SJw4lVF0TGaY3iNI2AhfWUDpd3U+ItOLAmsxjBCUh1C2Og8/W9AbM+WpPf9/qDP6DA/XzyxBDwRAW541RUJ3TsXrv8fLjZpVlBMN
# DATA eVYMUCJkjyz5jHqdjLv1WB9sfDgQIMUE/VjseZwk4gzOmNuT4XGvw225E6fqsUwKbEXI36wYmhu4mbVKBmId1hWnxJ2NZCgYZzGy
# DATA SS89GDMx7JEzTjeOyy6Mrj2yvEyGIxNfEqocJMXhC7rYJ6A2HMEer2H8GjmfIwztQe9JLaxM+nE59KwmwuUO48pBFzh/wWwkfLwf
# DATA on1GsPSofexmTYJnbP9LDMwocdA/iY+cQDpoLz4ddAqyjBjDYFgw4qGHsfJqp0XHMHHalxDr1zeGgNwNJcbUtWIerWDT4sJxNDka
# DATA dkuMJOAgsJkpqqmAFZ8lM1EbN0J4krwU3r757WXPz8DPgv8WLAwX3n47i8eubeyYfa4KXiCO8t8qm4Fx9QNuur6xrhhHgKp2aXJA
# DATA tnBb3KkczClTlVQhrBL22NOQUhJDy3yVWAec9IPDQtjoDuLm3iC8gcM0nBzkekV9zEgMSRCU96d4R7m6RePj3oSC1wtP4ZdWpz88
# DATA 6R7022AZH/XIeBxiyD2tGxnzVSFO+ELvHnaG9Bq/pZYu5VWZAoD6SQkH3E5Ex5zkxtM5EAONRATmaIxqlTxktASSnyptJFt+hF4d
# DATA YkaBxfGXMX9R+RuokgolbJ8SDnX+L0Acyv5JVCSOi5c/IwH+S7SX4vnzK7YjfMUXOkGDZaU+e04GQSgSOshgJtybHCsD3OQWKf4V
# DATA Sfqz89+JxsDw87G2Y/0UDzxjM1jtM7u7SBCOxXapNghyrfxo2BsUDsKnH52BGfoR+LmTR0fJmn6Z3aGCsHqYe5V5DfhsG1IbUlAp
# DATA kGwnhyDoU8LZVAzGJNuHEFsxQiiNxJDj0IAGrNzYKzdvfE8/qZjggc2nSyVIHIm1TRdf0lS2tGk0Tz8SnAHdhEMOMaDehjfw3xsh
# DATA RhMg1cuBmGlCcbX7sUaHtM9cXXmiuPw4/6g9nu/39nUq2HnxeN6SC9MKGbKizBOjuCg1fUOu1A0MoQhviNduhMlICjsQy8g742o7
# DATA jLGJmmNSR+fXnjiuVsGNGrKUG8DFiLqx2mLe7panJs4xfIHMu4YZZiK9y2mPwG1uLFO9iI2AtesUbR4S1nk02p3jqNwg4m02FOIl
# DATA gO1whdN5jUO0guug58Dv4Z74CTK731vMjvtEYgF1NhmhrTXaWCJToz3DZlI8EI24v8Er6otgZfVBXal7Y7Qdi8NsFHXEBRES2aPO
# DATA 5EnU2cGkJn97MgQ3wQB0Jl10GexMSDcTH0X9vvyd9CdCEGyP6BTDgegow709oKE98RcasYfX6OE189lb8Oytt7iHBn1QciLuMP8b
# DATA FuclLdwIZRienSAzbDwc9CZC1lgzAgq2I9uQtnt/x7wj7w1WDoQsU+OYqfIQRMSIHdUCDjjm1vYGH7ThtPCWRd5kdYYjW0R/dsEf
# DATA XwhJ8dFQlHv4oB1/VFsQ0t3eQM1+7ZpgdDSnN8Jre6Ak4oPq9vLyBSYIN0+u6ZETY0yK2Fdi0tp9GFNjF2oSb20OVttCDu+2x7Xr
# DATA ZfF/wcLN0uKt6sJCFfiUNfRtQVji3Pxx1F2L+u3TnahTu3kbSm2BUj6Gy0BtIs5YrH+dLJtNmt2oe/e0hp2P1cQ6c+GJMLlQcEmu
# DATA uBKJxkABISNU6ZlyhoIKwDAGQAgh9d7kSEU7jqUka7h8NoyICFMrLb6y3tByCaVTHeNBKNOXFW0RM9ieCr6CjzhoM9fBKBlMcUNZ
# DATA 45I/SpmWww9rMrNusqTF+U/GOCnuW6C0GvkjNByvTjXhhjewq+1qV6R1uV2x9F3tCmq82nYsNPTJdCVNeP2OTi3fY6mqm96M6fE9
# DATA W5sGCRlNGzfQdkUKg6JmvoW2K6YI7a/YCfAkQdMcCYuaZv0XHgaRd9VKzArzpg5t8ZFOQp+/LcMxGtDG5ClcIWDC5F0xhWR439mS
# DATA 6JvB96NohJZKiQAUyKMYb9yQ03nQ6Z8A2nUAnhn7w0kYB32I5+cLSVxJZsluhJO+jMXkbVk1JtPazRQzyYMyjeEVLRQUectbZWFf
# DATA mmXsdIl0EPA0WTCOfmUTCbpGEt5JP/bk82b5BfyUCPLMGAnKLtav0GcfSpJXZiHzwtcvf0bXx5f/TI4ZeMFE4zxcMMXJ7KSAIW9u
# DATA 0WTD6kyzeMf8CXrSzOGNPcVJ2u+lDEd3wmHZUoxcyIkZrO8/IsgPTODJKjISycTLj3pwXTH4gU45JzE8oqA/PKw4nu/h+b8Zji1i
# DATA RqviAmW4ByKonc49GbmJ0Vm3G5ouMez3hy426xvrJe1QIf6fze0Q+AoDqRmptNJ9Fxf/vD39UtzfDh63Dk/a4+4r9ALM9v9bXLp1
# DATA e8n2/1tcuLm48Nr/7xvy/9uNwLbdHvf6AJkQg6EF8kYyks/Ddz8QUixmU+XjqET6996Ako6CJWJMCYZPs1wADzqDSX8Gf7/46GTS
# DATA Uy9Q2MlsHoD8HdB/pIILHXYoUGqK3xy5/fm948Th7zjKLd/K9rqIBo9qT69fH8YVDhAU5+v91dbKffQ8XzUUvlP97LbJo9E4x8BH
# DATA 7Ddk1Xz5Mdy2dSDBC2lzw6gG8d9/gofiFbGsdwIPPz0QQtdjQHo6/xR8ZNAt/6cvfxlO9eETc9YyjkOZD0KC+B310ExpTPIW2m4s
# DATA fCobK5et1/Bm5XFbMGg52beWF/JAUtKbE1BWD6BHxXRIfk8jiwsJoHqj87tUqv5kZOO96co+6vX7LhSjbiXLnGYb0uiWqRVM0o6T
# DATA qp1O0ke2fhpMsWh9/QR16EAOX6o4G0Em2sJ9CUueOGa8ljwwqpH526wfR5zP2vfnZewbR/vD4aQl2WlBTFuJVWSdibgeiU0mJJoh
# DATA pH+vscolofotw1zLGkACOhn0JrVUBU3iRURY1aosTXnU7pXQ3heWH0ZOCuT2c7lXHLfHH6FmnV4i8BTCnAhZ87iLeHNiusvo4PWj
# DATA 4b7Y4GLQgG43Gj4WL/WHcQzT1+99FElFpbiLTcbtQdyDYw8vlq7mUczi5dWOzAlg6UppKjJcKNyEzuktuiFmTeoQoT9KVWjlbIdM
# DATA D90eZeWcHNXRj6ImE2TQDBYprdHeIFVvaNdoag4Blo1nRVRyLeCcqeIsbO/3I0PLuDWMJ7X5k3g8v98bzI+Pg/JBkOiG1Uyaig6B
# DATA lconcAEy1HSGthI94o0NFVIKbUH2cNWXKrFEKepySHupgnmurXWiXkLiBRSaZKvSn4ePMoqVrTJxTmEFKJRHXXlAlgKK/RVd4zCE
# DATA SEyfuIfzt8dHvc5RjWSmCn4pSanMTBwlXidsPsw+RNIQH6VYm/hRfgIYQ/tMJ6Tdg8eiELZQCMUX28wgHiROcK7QPurZoblGc418
# DATA TgLONJP+ePhDBV35YjgOKJXHSQx5pWnKLQtFRrvcz4waPfX5eNt/+EQqdnz6moN6f8M+UoKn3ZHSsxHV9gcKqT3/iudQ2kLU9PKD
# DATA spgjq4ggSreQeGSvhKyMNSSq1JRhcaCgw7Wlo/SnOCwSLdVDcNx043NpLpTjR3Ig3V7cHh+3gP+CBwWTKhKdfQYWfYcggz6LzRig
# DATA ps1z9HnRP5n1rwgeI+uXqcRAtgCdG6gwpBBcCVYCkOMEB5M4o2PALUU/XlBV9IMeO+AbLKPrgsZ2hv0+4xSVy3gaY9+It5fLgv0Q
# DATA zdUQWVEzOvEbnjCQmGMkqOe0ttLpnIzbHbRdLIK2jDaOzkYtOVWz6E0+IXea8QIshPHGtP2TkG0MjSZ2Vtz7jsV8PT6KBgzXzsFj
# DATA 7V7f0Fz6O2P33jSpZnCJnLs4jeT1tkW3cPZC/onYvC8givRTm7bPP7sTkH8S+jR/Li2wqSIM8gP+QT78GqoAMyk4RaMHpAXnqnZG
# DATA oWjPl3kkMQQX7gEAelM2nVcOdZYT0Mv7LtNSCHcIccGuqR5t1wEoeq2+nQtDi6uhIcUV/tpYrDYVpJN8Vl1sgtoVcOrDJukRzd9N
# DATA lilrZZZJwWJczULTMZtPE32109vz81+hgztQUdIy/oXS8hcTbnzhvFh2R0AHH4JKf9j5KHEvA0d4RAIZ8A1SfNtsrW7XV3aDZ/Rl
# DATA e+2Dbfl5Y/Pdzfv3Nz+wJBXCvxdi4/hkBIgyEubjYAy3F8exFdHmHQyR9Y1dE0IkG1IkCSsigfT1G631exuu0vb70en+UIhH67Kn
# DATA hWI2sslMvfIDnRizwobv6ddSWCZjzkABJm6b4mEB/lPiJ4BP0qr/IEMznZAFNa7X5S0MicnMwFwJlRCDAo74H4az3knnf18jqMDL
# DATA n2HEDfFKvzYqtM0e5nYyDB+z2TMyMGP8JgezVWV0MG0XGMz7j6hW+3mqDs0zQClRhH9sNgZK9VJuH4Ir4isyAWTq/xcXbt1evunq
# DATA /99eeB3//438vfmGunhDBurR6eRoOLg5d+3atfucuhty6RCVSCe1CuwTTvVNabwxRwCiqkFmgPHw5PAIJUIlNec2DBy1YzAIqK/H
# DATA 7Q5ZCgA/BfUYcOTQj6D3BYCTbYgJjifvCdbYvwp4ASFCqs/gajWhZtOND8AzLGsDNnYy7ou2KmPqnWyTO1uCn+HgmFMdIN5jtKId
# DATA HhDi1/sLo4bPUXZqNKizvb6Frv5CkjOyDMyt3l+HGxOuOeZmJ5WLlDDCudXNjV0hiNW3AbJqd3vzPha3xRBQpo6H/XBup779/vpq
# DATA 3b6DMdYbUoxSI8493FjfbW1vbu5q2cbnLDa39XAbkmBAKs+UOsuPFkXLuyv36jsYIoVaDM6P0h0+HqAiByOlKE0jo7lS3oiQk2Oe
# DATA 8gvgzNEbiKVk7NfegfylI8h5IF4ozj1Y+UHr/ua91t0Pd7FJI2xeqW0pCdN4eCjmOub8MmO50oKgAIoQ8eBLQfRIh8eIXbEF4ZPx
# DATA UbAPJjaxj8Q8jKhMXOL8GFIulWJ0jNfk9uOAyVBGgsMeo/sbUVwNlJqtHuRMxAesjKIrt52iwspEih4usH0U8DSv+DyrTYyEfKyd
# DATA YRcO0Z7MYi07IfUPulCawsao7zCSgdC80JDFHuZEp8XhLFS06gTHDlfMqJvU3DxEuknmx7m3Xd/ZscVuZ8CUZUSuK6oU5LicrJWD
# DATA IajFMAIU/lPw3L9lNdYMa6sBSz4AIL4xnLwL5OBEkxkVPA1xltA/h3JT4L+oTo26KwCVLXoEN2qkJAAkR6xxhnKJDUR2sU8e9Yao
# DATA i5MNNLj2pkIvgJcEsxBbKsJELsCDBKHGUhsC+Hvk1SQIFsyH2hcKNt5jIV/GCqmA1rQCBuQnBWwJImitp7JTxeToG8Yomg1ZEFyf
# DATA jttPCgslXIqyOxY9M81iosoKcRbqS41n1H6tJmrlVPCwjXENwSkNQhT2niwslPeeLB7sPXn7QHz4zkGTk45h2aK4gy4tNOfsQfDC
# DATA QL8Lnqc3gsbTsK3XEWsCNHpiIlRQfMd/z5rFRnlpueq2wXn8YNCiGVHRnC/3HWYF5Hd8Pq1Ui8vdyL+r6jCcJC+wHeOxXEJT60+W
# DATA 6t0v0zeow/OMjWrfMNSdwvSwkt5UxfQ++nc6kq147lCxs5+U9mLUjzjaSk/Y6AjRxtn7k4uEPMFwylOKa9URm/UmuWrCyg2g/eAb
# DATA nsni+ZAVQxPNxW7uVdQRyO0HhzRXaW1K138PIE+JqQvOrd/G27p8TPPWwHmrNr2JDvUUoDtKgbd7fHJcUJU2sMJmZt2CORSm8ohi
# DATA MlknOmeoTtSCharX5cNdK86l1UeTIlhelM9ctxeP+u3ToI0RdW1IcRBcWwgYbOBaxfU/yCZZwyswkQxWiKoGKevDI0Gg8iBZh7mC
# DATA zEdI1jeCRfnDqph64Dv9aFCgefUlwkDS3ZlgYgqrLKd+Y/LHCzY24SZGisYd4m+LCwued4gAqHPXscy82Yrbpdg4Fo0tox9TFgvJ
# DATA LKt+FupUGvXboxgyheBqiZcsqiwY7RwIcoiPqCGShx4DEXp7gsdXMTECiAg/ho5sS+oy2pWPzOM+eaScCXbe6QtSsOQhw8lSKosF
# DATA sRDjlwgf/eEhM332dOAzF7KOQrIfT05LyVUwc0Qyq2Le6Mr1ATreKwQvUZ2uJUc6s9kSmLEMaGZtUeH3B12/evWD7c2N+x9Knaql
# DATA bK3/YPV+prI1gVCgRDHgk8k8k1WXsaryEJQLnYdbghV95i6VXrwKwRXJsEv12ErRSX6/+hcKHvcADsgyVgraNFQEMSOdPiQBPui6
# DATA flAGl9Kq1YMux/Un6bKF1F2gCxDfrSDOY6KDQPlyRNJOIWyAjECZ6SbjAzzBw7c+LL91XH6ru/vWe9W3HlTf2vmbkFz7KofHdMaj
# DATA GNFErwS6h0DSKfhGTZGXRKgiasOTyUH52xCNCiOPayG7eUgZhPskPY+Sw2I0Jqa0yNifNtHkosqVra36xppLiqkOVmq6QaNKPa26
# DATA DvAp8x8ykjPZhiQ8t1JOQzoq5dlBPxbz1ixu4BAmCYh7cGXKpjCDiVHmNolulWBlclukTjFOTionZAb4zc4UbxD4yeKzzK+yp8YU
# DATA Z2mGpNLEGB26u2mLzxVxduseDhqVhxsr74tpWLl7vx6msmDZl+TSTDN9ba+Zu0DSvf6+gdDw+RwNxxJWBIOe7FU+FjyAIZDQbxAw
# DATA M6icx2/QcUKp7LTWd7br9wqyEom1kRrFkmMW9Q3gZNBp00XDrJ+hPizFlm2Uo97HUfSRFGgS75ft950hgnqqJuuB20bBLu2h0VQD
# DATA TvaIKRgYX1QYDnLcZk3QH/FfMCZP0OmtsI88u7FEFxZVolGFYmMhtXW5CAjAVAhcv7keBg9LZ/UZvYkGXb7JwCRDvtbCOCzDHzBq
# DATA QDQImtcZ2z34fv1D/Ckkz3M9z/vRYW8wSKnobv3e+kbuqgC9gPoERz4CeujaQfmGP5KnhZALvqt/lc8ceuWJChvb9bWV1d36WmD0
# DATA oYlnsCjR4HoB26nI6gtx/RE8KtaYVtae518lIFTyHmsZtOj22qB0IPL6PasCQF2fzOzFteCpbJFyX5YUZ+TMpvKrJ2MdizmUzM/g
# DATA qfKRvPSDVhmawhSE8sfKYX+4XwivS6VGo3p7GfRFWEiV8rYcCwkl8fbNJQ0dRk2C+MmNZ2gTEMTFViXgOwlWZ5hZ8R268hhiPB7r
# DATA Hn5nzDe4kZBZA6toGK83i8UrvygfWLnpDWm8F2VNifdA8qUcvtDxdJkjKu3UST2vMo4hxueY9AYn0Zwn0MVIAp3O/3OyT/N2RGip
# DATA SJsVYM5wLxLc7od78fXCO9XoCRjH9uIbxXcKDAnTahroMc3rRVGwBoUr14t/Yed9BmNN5UGx6tf5aM5K3OcZ0MljQerPkK88Yynv
# DATA mQ6MfAYYS+98FJ0+gyMTlGQQs/wsbvcnz7oxQgfAYBqLTWx5PWWW5RajwktNw+MNk1zvXdsLw6L3VdFxUIhgDcXgL2vBcjU1QMnh
# DATA qfSOu6cSgmRiw1A1iCIyBG1G4Sn1H9Gf8BP8xNzdwxeIDeAB5HT9DDEja33Ib89IL3SjN/YinTfwj/Kpp7ZKxiHUlDEofIxLFX7h
# DATA nd5xsdA+mRyJLf5jVCUKQmlUa00irn1BANH4mVjIXqcINLa3A5g043Bv0ajbPFTdFkJuQ1TWuCZ41jt7+xZxiuc79dXt+u6zrZWd
# DATA nQ82t9eeYdaUZ3xstt4R5+YzUWCtvrG7vnL/2crWOj1bebj73ub2+t+sQHaholspN6YGU2z8cG+8N2jeCMPZBjBdqGjsxXs7zevv
# DATA iFaniTLP/qIYllKFg6xu7O1Hp39lDNKEgEr7vh/aNJBVfwFgecTrTf5X1HGjUm5er87Pw9TF89+rNm9U6VPzxvcSc/i97N4/Wdzf
# DATA azQWyu80rzeC8rz47/fK/11aixLvSUivzlF73O5AgDUC86hvYj9hSVCQmg8hPmISgtwmmJR+GzfTzaWAfBytH96oBYtLb2eJrEqg
# DATA W+PrYsCpL2OK+m7HE0JyrwS7R5FS2FqqO9JUgucIYbWjW0UFYPhYHrS11PLmJ67C8iMlwJ2QbhjeAMgR2Vl4JD+f8eW2D4i9k5Zy
# DATA RGmxn0pBW+C3yQgeHJ9MwPs4uI+vIAZ9Cfo5EOxogh0G7wlyEhBf2xMCng8m7UPD9D4axj2+KutoTxJ5tusPNlZWIXPTdn1rc2d9
# DATA d3P7Q0qvO5kctwfzCvWmrLrr2s9SsdEEnc8734E2VXfyGcW36/frKzt1Fe0pzXrstFLQiqdQ5jMSJ13lUEglJ/vgUjuPLc4/1Q2f
# DATA zUvPoHlai3eUW0cLXTdqT10v/TPDCZ5wyuLa03ClA+cQqEXAgQMCUgAf9dGgy83fQIm2BAnQRb3lVTYQVkEgL3fgWeiJ0Q0fCios
# DATA rxxyemm9BOY9IjyjNw3HT/beKSgnDyNlBghh4ygeDQdxlLiB8nOSiZZu3WZPErhiqrWG408UB6u4LnGhBcSZt9FMoGKTqIxjWKWo
# DATA BdTLi1CM2Ao4RqyGUT3ah6jU0pRccFoVJfjoZ18Rh8wf7XUFT5f/AT7ZPnSiNcd2m91x+wBsLb0Y68MMlYlCI3GiywzPVsmLDJzz
# DATA OsBYwAvdCvviZ8yQZEkSb6opK2EKRP5ZsSZFHLn4b/EdMT1mzVMG8X59e0dIDUr5NsZ79+REsO7CcXsEiKpcnwQ9h4RYGiVpcFqA
# DATA l4BOF5ffXv72zdvLb5MlA56KkwirvEhfeO6oSzeCwkKpKPZBYTko4+6genXYrOVOU8202PivXV6fbtSEj1MAhVnjxwHCuJ0BO/eW
# DATA tYsRV1qi6uaahp1dyOfHVMXyv7F7LUR+P9Hk37xmWzzhWAdPK3tSzESpoJRGfv7w4foav4riBX7MubP++mF9Zze9X7F4NDLdUFoy
# DATA Yv5YnDryG+eKVVDA1Sneb+wA4XECmzNwt8V320Qmxpyle8qvEH+4sbPybr21tbL7Xmj1KJ9dUxZOWDWTXn16zhQl6ckyoFnpGWqP
# DATA XTQsXT4dEMsgElVVCdVUriXTaEh9biw0HaUfBYuiWc7Msq3eKBJfX9naatFVCsVqH8YXeDrXAhoJw2eZ+iSlqLHGZoRQgB7CVrn+
# DATA ULdagyvEASB8Pr29fCY1DaxhSA5JKgIQJpfyABkAssxGqDToXW8uZRLRg/WdnfWNe3IC+FQGLQVgvh63O5VB9JirU/C/pYC9bkvS
# DATA /boSH7WF5IHSWLd3CKJf0eM7lk73JSG+k9K1Ss2fOSjesiKgqYK5cYuJPAa8QobUF5sIguxirJDBGxJwENwDMVRbrxw4ryDqGDuy
# DATA C07CmICF8NGwf3IcgSNww3IRVN6RDXydVFH4CZI3UY29A69ypWBsASzJzJnyOMEDKSMhaCK6fiUcsIHF5K1dKVCSbtyys/Igr4ZF
# DATA IZUsNYtNQ9OjtqFYvdMRXLzC/d7AhHgkQDhmNkUN+FhNNsnu1S2IExC/A6s6m/N5L5heBnBUNGRHmr7oTYveuanWg82HG7vQ8Lv3
# DATA 11d3PcnQuHrHcIerJ/VeslUfpdtHi0QENhqQU4J6d9NLWuWnSMtDnvIi7CD26auSXAo+7egiKFal10U4AnayrKI5d9a8T7x0nHdb
# DATA VhKEqInlr2dJwFcA3I26LT5IjVzy0h5dTEW14IDtwhTMV1ASiCs+EDak/A0KxF9QbyDdOiW6hYuF6wBSJAFv4x4oJkyMWxUAw8Ev
# DATA Qfkumt6NoVF0hW9c6AhCEbH4kjk78BPqOBKdAvAOaHo4KLNnwt6AnyEsrQ3Hmx/rwke6OvJiPuCAjRIHn7tLm0gdqbEFklAZJcKP
# DATA MESQ7NcVhkZYLg+Gj8UH7s3MNY1pplJrkJcCBEgREizo5CenLDAakouhAQIAXMA86wPHOlV5TwUvxEPtjqQ7iOlsd4MJYMfQsRq1
# DATA xZGN0610QKkipko8kH5wZqQhsERNKZteSsCU2JrUlodR6bgMLT2aYK+Zgpl8xjMuzoHIlBuzxDXu2M2l4Ls1WwCqBcsL37mtMMuP
# DATA tE2BdaOEY7w3Rogd1AeBe37YLP4RyU0yZUNSRlI+mqiRqqqY7FarJ3ZsqyW60D8g27IZsSweVtLJThXRVxz9hnnPUc2hyIVtJR3h
# DATA jXuEWad77hmVtR9F3O+EasKalqz6+F0nPkGHrJO+tJvsMxq0a26vXYs7p2V3vN17MrSLoWdBCAAvbYpwYsN/oOzmVEqwVtkbP/yE
# DATA RXgbm7ut9Q1xEb8P3mC6aakmopobIX/3wHQkSuhpAYcuJhippgQ3APM+PD1eTOHOgTO9L+OUvGDixBLlJHwAMmPErsDTSdoHArks
# DATA Un/rhmyJKQkzQImT+o0RBwOlKOJCddlbWob0I1A8n+uWX93hTmrqbiuE0BSOD5fGDXPxTz5PxateAKdj2avAdGy5IapNavgiarpG
# DATA X5bkVtdAnk7kbKWPiSOMaouW3zUkxCHHAqjCcWRynTzgD8Di8q0NVN0Q4jqGdPlXiFdJ1GnHAWGYo5izkwgvYDLgkS54RvxRUNbv
# DATA moEEC6B4fHtpISVOBd7huDdssSbjJ9kXoyYodLe+vf1wa9fiTKrLODJRC8GOCwmqqvoBSOFmYgGT8MRQzKQGPFx170B72CGoZkIH
# DATA YHx6gKS/aypgyjIujjg4hdb8zDiukuHVzEQ7R+1BknuizhgJAJE9yIQACuN2hzBxvBxG/og6U4NxpgVzZcl1W2vgIHD34c6HCf/P
# DATA U18gFXkPJ4dZAcTLIyG+9X4cmTuQxl30LYavljX8J82lM30ghqsz+XSSj7K56VvkbEjLQZxZ0ZI65GY92XSoqgoulvcLibJkXDmE
# DATA zH44bnejHGd7OodHhuPlVGJoqIQw558GKiSK4eNWtxcjbpkFtZQYCIQQyn4iu4AGibSO2wNRXZdsXkisU8extXKv3nqwfm8bXUxw
# DATA OOvbFk9I3QPwNWUH0E+vlP7Zmzz3yTl98xjqQF8Md0p8TvLsrWWcvd6XNcvEg1t9TffqmlnkcBiEbH/6wC5wYNkVOKfWdzNOrZnW
# DATA P/+JoRzZXPmLDgoIqKMwe70OVZP1GItb1cK21tfpWTFjEY05cfVu9p70RGw7+TVSKTZFlUJYjJlIhaxTKyPMG4ABGgCGJjTHoSVl
# DATA +7WQ4j0FYqhVW1Sh+oHRlx60n4ASDGgACrjqOXzpLih/UCmX2h6D1MGposW+EkunkCkrGnP78KDXDSWjFY9AdFDniaVdshw9fMRW
# DATA uCBWlUV4UwQzcV3c3m2pCCKWl2rJUKc5v7unOllyiuqeguOwzDefcvPpzdtne1zQF9U1AwmnbHFrwE6giQyGAoBaW1iARbZkhQsK
# DATA CFd+I5yJNV/4EHMO5WJ1ygUzeYzluTuS0T8BYgD6EWZ6aSKo9RjcAx21lIxpK+Sk0qJbYaszjjj6CSWS6cySovMQCUUH/Bn7BXLb
# DATA sBtivg2RpG67X8BS/Cygoa5BTUZ1Et+LHoEkNcIQN43cuzVz+vTJpeC+jSU0RI2i/9p3xaKrmn0tv8o50H1p+uSQK5F4LyX5Xvk9
# DATA 4lLim+/wUGLYZXgyOUZ5IlxV2ngCbG2s3l/XY0umX6UTV6oqEdcGfELDZsZqoj8EV0xrmVYv7klTuaA+N/0noSMbXaekL36Z4BQc
# DATA CmCCur1BzXhzrf7+xsP79/EXkAvk/qN8U+qrT4R4e3FhwS+DZ2zr1c0HW/fru3jy21s7Hz1oaBkpT+hM6TPGUV1MwukdmEzQT04c
# DATA IE8wAdOnSIbLi89SBLmQYIX7fXOrzvvdK3AwZzJAPZoePKAce8yytpwk9JmZanU/9o/nopUCMoK6wdsLbuIazAfQIu0mj5PU9fb+
# DATA SQKvJ3TuLE7ZldhT08akhrUpxt5ezOjo9mUFutDUO+lW0ciYhOA8XqUbtJgkOMDn6QoxKKBbgQbo6Udt0UOAM9sfDx/HkJyYtRYA
# DATA PQMUMIn6pxU/t0xTh6Re+NN/zGVlSRfcLPLwWGLEdBlLX810I7F2EcPWs3dKDi0yaPPltqkZhFrMbhOHjFZE+3RK5nE6GY858hDe
# DATA 0WbBGUNEi2nVenXJ169zzsuw/UgMHt0cquoldi1n5xrVJe12wwWTF1mFayYKuSBshoxFk3Jmmv068t4DyabcUDkyMN9PUBvZmTGR
# DATA Y6tV6A0GkS8oF59jnCjDHZCrtHS0dm24jAOKgOWlJAi5BZjjguTAhN7wyC1e0d1F2Nb9dHC2RWsFxJSCuSHhwvh9424xUyvmFdhl
# DATA HjJoWIha65spWiZ7/jJPN2uaLarzdCp5u+G1fII+A1hXKbje8ge46qZm7jG3fx/vl9aBprT00tchefemX1royl8ybuI6lgIdTUqp
# DATA V/OLa51T1C7T2KvfkD1Nl2tpKC6lz7ygpT2rg6mdm4YueKEBKMcmWnVw55Gr7TLsfE2B+8RG/YP6ttPQm8HmIFKYuiho/GgoBtru
# DATA Az+OTw4Oep0eOnZBXJ+MUYQQLdA6wKy0xQXuqBcjqE0iFN0E6jI5HqMrKDxKCbNQzc/DmNgtmK4GuEAZKJfFahmfcO3N1BDwyyN7
# DATA ZSN85bwzpNSboXRXnq90YfIp0qXrq9a2u/6szHr8Y7qQIj5VEvlm1O9pqu6ESt7vAFNKVcNP1dl/M6p5Uyv/x6KCzyXjXqVCforz
# DATA EgScW4VmUsNnEvBVKd8NvftFNO6u3jrtRL+031kubPIMnXVvcDD0aeY5rDQLLlxHIhECUO464qMZ9dzwu2lC8GnXp5Bc8UoU59gL
# DATA 1p5PJ+ErVpy3/DZ6Q61JVHZYzamOQ02TVrHzlEVdYr6sVsfe2KcSuoEB6deMmfaf3xSl5maNNkAENjd3OR7H4qK6BAtif7V51zon
# DATA TRwCDGJurW+8u9l6V2xwrg8ou5gaT+KpoL6xu/2hWQMStuPA5SwTnemwSDqHw9xM9397f9o5GAzi0yM3c0Wc/7tO3EO5fT59+XPM
# DATA y/UxfLU8GFLuRTIlYC0DZiKX4pmU20IAgP6VZVi6oytXlTcxorAGUYV5Qn6maqyRllldjZ99Z+130lTVGmRAmxKRflJKo2d6V8ME
# DATA NIgXqA3iR0JS7tD0ur9yMM+RovXg2vsyMY1epqfq41mVE9s8lRWeqRAP8Qr/5t/AZ3uDayoEIL0fvqzSxsGUGFDwXX0V8rZbnMnV
# DATA R25MuCBt11fWPgxn6cpM17ILXM8sB3umArU4mlW+UdOrd0FHJxOkwdM6sqlElA0IBeqXaTejCzf/ZnCXtMrQHqXYRVz84/YpXLcw
# DATA 41I7GESAGz+iLDE6z1Jlbqp2VtEzT2jNT1dSRSNLSTJQwi5Wl84GXxF3/hfNjK0ca5BVrgq5OiHP3GfnX778RUAnqew1pYPJx3f1
# DATA DWa/LSSrknF0GVZMCfDo58amcfCbYsup9OxuV9hC/mWfiaAZm6P1YH3nwcru6nvhZVaZEyvBIv/b+a+S2VJ/h5lSIZ3eP1AKwXDK
# DATA ok69ruUxeU4T9Ryza7aQ5686VedD7XqynSSdfrJTERWnVu9mz3HyPxhpdFyHzenpdLL9C/yWATvRCITEmTmKvL0+SxGXL2DYydRG
# DATA vVIj+JuIksZXD8KQgSDCADXs3WD/lGJMR8PeYFIJtsQkQCBxsIWKlvlBNIFLtqdWVjZAdOqwhPcb0UbQGY4gr5lSdHZ77cPBMJ70
# DATA OqDCnAzpfOnItOgXMtmn2ONbJoR9fjWosR2mmr4uzIsS5E++zdwy4XDoQylXeH0KT/sqlbHJpGVzV0nPCVpGxTUtCgbg73y4s1t/
# DATA 0NpaWf0+ZEyRnk3iIrj1cDfMGqk3b6qxB1bx5Nmyt8GgSwTgGOnfvpXVEs7/tIytxjElE7byrdersLqQeo8nzg14cxKhX8w/JJcE
# DATA BdcpqXg/7sViEg5t8J+ESim1tMoBM+g92UH8xYKZ47Kye0QpEQ8f9J6sD0pWAswKvoS8il6V6QEQGKA1wVdjUzkD2kCw9vCOc11c
# DATA xGkwoGjwUtDudnm/xycj0SuMBFEvFj3vAHoL304LtxI2SU/dCj5K9L2AMffcF5oSzh9a8KcVLZp5B4gdHos6RTWs6kyYV61NSIgE
# DATA o/6pjCUTW6CEGGLOW/vD7qmNq4GF1I3TY4+IBt2WxBUsQKm0QgSmWAhXCUKzDIAYMiOmBFT0KCk9FVgQiyWEWES0hTBv0/ejweFE
# DATA StxgzIJxu/6m+Lp+O/aN/jEapknEwDqsKT/CxUujPzMwPpuoTDgALZ4RbkMe5HmfKRphBUA0bY+jFqMFYG94tIyPYIISE0SC+M9d
# DATA BCTGmw+2UEy37OK5h5S3vHATBCxp3grf3dy+u762Vt8Iz3KoeOXtQmYjBR/Ne/Vd8rbFX0jNDPliSY4Is+3humNLgGlG88a+cP4Q
# DATA 2RztUzqCGASfQjgPSm4K7Z9P9bPN6o3SYkPVZIV16mxebU8Po9SOSnTGlP7Qm00J7zSfjQtO+IlwO1x6dRFk6XOKzSP6OX1auPg0
# DATA EsFxNO/svaFQ8ku2brkjUxTshWjfE3mcs2dbmzuX7VofObKiMIMJtSCBY5JzN5qZJMb1Eba0CvO0eNvuuD2ID6JxuQ6HG8UKsvqN
# DATA 3xaUUenFgjn2Jlo1txB8F24tBV0GVZY2SO6VETPjfBoIiLR6eO4g7KfTl2KmO4YhwkLNEhEO52fCeKFvgAsE4p1gXDzjkm1Hj3qo
# DATA Xjj7presjzCxp5ckTtx88+0OxVP+eVLl0q3bf0ZECSvmwXDQoWGvgjY1p+b4f+hQQ/alSWK0FSskH+l+NfOT/dKFzoZUIiex8DV5
# DATA /ymQt63G/YYI26TphG3mKug4Xaa2LgfL1uUATHfvbj7cWHMvB69ULWp16DvkwaMUQLCdTN9S0vcsi3MqS42kx3QBXZK7jsZcdIct
# DATA IQ8CPJx1xzR/B57gL0BqFemYQ8uU9JqHUgoR0HhFQfUhCRvP/ViAzss+a6f7O34tTA9bZkzBnc3V79dNKjfrszxG0ePGVD5NpAKK
# DATA XHRKUg1DmOtYqOqtVgJd3zYdE1hRhf+0DoaYLAgTrPbAH56TawIdtVogxbRaocx6PI7RkUPsP/xcWRkfngCM4Rb+ojJtgYW0JWSg
# DATA TqtVNN6E/GStNr9S0C6O6Ly5hRpwBhrGb+J+NhxN5pXLprTceCszT9rO0RCQjWsEcozioXaadJANECZdBp2KqShLJEwsK0NLmpnD
# DATA kHGQmYVIeV68k/Z7v70f9TN+RzNbdhPgDZpeAapNM35n9N6MEoxLyZ3gYFYui/9Aaal/glBVPEyjkx7bWBdcdMkddPOtP4G7+PYJ
# DATA 5bshtxLa2wq2GnKFAK3opAqioYodCqvjgObSzBv4Fpk38KOYMP6Eq8OfcSX4M866REf3t0sUZOJMAvC+2xQHP+Fnnmn+xrOa3UiC
# DATA Oi1INxvC1W06VwO8I3S1iK2p6ypW0GFVTlt2ZeYey6hR40/gQ/za6+q18aHSk17arao4963Xf6//Xv+9/nv99/rv9d/rv9d/r/9e
# DATA /73+e/33+u/13+u/y/z9J27jCtMAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
