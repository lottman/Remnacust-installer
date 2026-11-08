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
HELPER_BUNDLE_SHA256='057580a617c028c4d92276ea79d0b550fc17d8ff28a43a5bb9ed437bf36d6269'
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
    elif [[ -n $NODE_DOMAIN ]]; then
        NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?
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
    if [[ $ACTION == install-node && -n $NODE_DOMAIN ]]; then NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды' "$NODE_DOMAIN") || return $?; fi
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
            case "$choice" in yes) NODE_DOMAIN=$(ask_confirmed_domain 'Домен ноды') || return $?;;no) ;;esac
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
        ((cert_status == 0)) || return "$cert_status"
        lineage="$ACME_ROOT/config/live/$domain"
        CERT_FILE="$lineage/fullchain.pem"; KEY_FILE="$lineage/privkey.pem"
}
acme_certbot() {
    if [[ $ACTION == change-domain ]]; then
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
# DATA z6Gvf6EMGTXk+7+VATF15r9QX7+CTz9//7+//5v3f/3+72pAF/8O679cxeMZifzpAq+XJQ3xO77/sdtq5uv/NHrt+h/q/3wX/7BA
# DATA 2QZ5siUdb2Pb32g32sNo2Gn041an0x72mvGwGzZHw1Z/OKz3gka8FTeb3QY867d63VHUHXZ67bjf7EWdRrPbHG5g/uMGOY031EU9
# DATA G3Kf4oa5uWeDqinCD63WVm9L5UxuWHD0+o3eKAJqCIZRUA+jUbcVDeN6vxd0R80GvNUPO51WvxON6r12b9iKe/W40Y2HQas7CqLO
# DATA hrr9hvrVV50WgdDrtwoA6MZxI2gFQRwOo61hb7gVRFu9OBp2m81+2Oh2ho0oageNRrfRaGApqyBqtltBexTWw+5WtBW5ANh37RXB
# DATA sNXpdQqAiHvDXrsdNGGUrd6wH486Qbcb9oNm3GqHMOGo3ey0hqPhKArCrf5WPQr64Var3w/aw1a70R/mgCgo+FUETKPXazeKUBJt
# DATA deqNGFZ5BIvS6rWH3agbd1uddqs9wkuWonowqjcBZ61+AxDRHAGu4qjRaLV68SgMXWiY/QyGdMXmOkganULq6LeAMvr1VjuOus2g
# DATA 0xn26u1oq9ECNDW7QSNsbrVGvWZ3a9jtBlGrEwNm2s1uO+r3eo1+GLVcSOieu4EI4TWQtHvdQpRsDfuNZoQXS4WdeNiM+gDScCvq
# DATA 9ju91rAT1evNXtAbhvVuvwmruNXphP1mAI1ge4W9KCwAJFsDQb9bSCJRGNfDYbPfGYWjIGxtBZ2wvtUFWuhtDev1XnfYaMTDUdjp
# DATA NgGYYKu+BaQa1nu94bDX63fC3EYBVRlAoOOixVA0e71urwCMoDEMG2HcjKH7Vg8wvhUNe6O43oDtGcMyDpst3DGjXrfZ7veAYbSg
# DATA 3bDZaw47YQh0nAdj/rNhMF1HFcCkmgUwwDqMWsPhMOh2umG93h/F/VGz3WuOwkZ91G6PtjphDKtR7/X7o9Fo2A/6zX5vq73V6sbt
# DATA OjAvFwa6fW8EWs4N2NFrINlqNQt5R1DHm7p6fcBJN+53+40+LEt71IMhgWm1Rv1mvTVqjRqddtzoNyLgWI36ViuMtrDlVrcAkAyM
# DATA rjVAwO4q3K5DmPPWVtBqN4H8e2EXJt2Lu/VhB4CO+/B7q7MFfL3TbAwBn+FW0AbG32l3mmE7gq3VWwPFIAReNk4v10ADhNYvJNRG
# DATA dzjqjzqduB5E8RDQ3tvaGgLbjFphPegO2/0YpAqwkGFUB0rtx1td0AS6QWc4bIRB3Ki74JC+P5CczGRxu27btjtF/CPqRw3gC2ED
# DATA /tfttNvdsN2OO+1gFHc7vXonbkRAkqN+oxPDHo2iZmMr7rfrja1Wr9mI+1EOFmUZF4PQawFPKoIhjmAXNkCqtQNo0w3DJvCqJjCv
# DATA ZgjMptfdGgFfAZbVjJv9CDZuD54DdGEIG6cV54iEi5cOSJyvw0WjiEpgM7Q7nUarH4adVhz2u8DZG/V4qwHE06q32yFs0B4QbLcz
# DATA qsfN+taohRpAv4UwRqM8K7WtrnWyrg2rW8jTmyhjYxg4DLqtMGi2gGbbUQCCrdeN4n4Htm0XxHu72w76LZB1XWB8cTOK4KWw0VkP
# DATA yMBcY7lujeqFJNuvN4J6HGxtNYJhu91obgGzbYCiAz/0O7C3ASNAosMtYC+NXhiEo3o37IIG0qy3t5CK7wEpStHCXsfqYYsW7aB2
# DATA v94BdMTDEOi3G4EUbjaCUasLRAqbuAto63frXYAOBHW3AXwPoY7bjV6zDvvonqUy9QvXsdxmvXAjAX/bglVo1UfBKAA2GoSgNPWB
# DATA RqMGsZYuKFcRyCOgqSbo9iMQQcMuYLPZiYMQdLd7QJrdIwub/Xa3iPG2mgDL1la73wVmC8ppswda4wiIZasLWuMIdIBwGPZ6zU6j
# DATA Oxo2hoCtDqwfKC91oOdRM6cvLcZrZXF7q3BLN/o9mCOIWxCtw0azA2QThmErjkYglWDrjkAqIoGM2lEzDob9fgQtQRKGw26918rR
# DATA y3J0M7hcBvNoHacFcigSPqNW0GjBlu2EsImCxqizBRpPEHQbYQP0pNGoOwq3oj5A1Ww3QJ8L+6BJh1udBuyrTn0rhwP2EW3CWqxV
# DATA CVpgARSpBPV+GAxbUQfGCoMRUETQAY7RHHWa/QCYR6sbAFaasB7t+hawVqDgGPSGXtQYDUF7iLc29MUHBMwGX+yExEhfr/neXdoY
# DATA tWat0QYOcOd97w//Psz+Nwr4v8H9313QzvL2P+gif7D//23r/36GtSKCqa8OXcwl4U3K/2LpoGQyWZLKUfXT0YhqpDE9+WGK9wje
# DATA V/eXr+dU3+L5fJqqL5c/S2bqM150M06G6muS/u7Fga+Wi2Ss6wMHc/RT6K/xZGZ/55LBmJ9wsrt3hrdeFDnMSt7z4+Oz/RNMzih9
# DATA M/2+f7L/4mh379Xp2eCL/cOX+yengy8b30Cz/aNn1Ob7PnwarGu1e7T3xfEJ3WhOrlo8ITYfbpQ/nVT+nFsOPnt19Oxwf3D6xS7w
# DATA 2Z2SfQtI6QcbFe/5weH+KaajlPIbvMR5nqKr4jfbLZF3mhf95ugJ9uXFJWOx4TvakKXbI8fqU06Y6JaW7a1c+Lbl5QyUU3RXIJxZ
# DATA I69XAleean2M0FLgKMHfHeuYJmSJaL7TcsUq0RMSC875btlS+Lv4yfCj9liVKt6L3Z8MTna/wtLyXbeIBj3CBYdnzdyj3MmyqIyL
# DATA reoaYmXuKA4BjrJTEUMiQ/RcXXEy5MtNqkTgukyd3FZidSrvyratyRFfaoAZ1eqyXHlfxPfgdaxuW9721halK1GtKfWf8qfbm9bp
# DATA B/x+Xtu8sH+qfFz5tKRipPeecZD7C4R5CVS6OBPm6w/whoRYXechiZoY9lnQ1ZHl0qY6REO5F6OEj4gtljPYvFhjHEMrGOGV0otY
# DATA jyjJAB1Yz5Erx5QbXKeo4t1XfUCd3TTQqNKdtZLu2llHhgHvpEn46NjcfgVv/UVcD9N0XDadwq/WTHSpbCAV2nSCTpYIOzaB8WO1
# DATA irxDQ0xpKjOPrPg/8hv3LcYzfTOfLMcoTRfx3JxREl6LRUemTpiNvlalvS/nyWWqMni+7CG3rcXTiLN3gC0/mGN8YG5nKoJQLRSJ
# DATA w2QqD8+3N/FUD/Z/wSDh86ISyghWGR/aWUUoMp7tnu36JamgaG8MfLi3u/fFvm/LAdog6nureUd7AfutVB5zsv7VNH4z43tDnFn6
# DATA clWRWQ+cF4ssXSmHiYAyC+9d6xdyIaPRMWSsYBqCAuHyI17OOV4ePiszG/I/YX4k9KkgdmhU3s5BaJFy5bwuS1IebpQ2KueNC80W
# DATA qTiUZnc6oeWeAUCgQDfFYnqD4K2XgDt32/gZhqvau8rUSQ5U9ZRJ8CaZLCc7iskbDvlgwc380fJV/H/B2KbTDlgxDHNSluNgTjUd
# DATA zBl/69A5UiMPkM5g3UtAfBU/yLBZHEzMWHQF3o78TKcQyjIT6LPh0A4JB+AK8vwR8FKts0Wa+mPMtHGpJC/r9HULXCejPA+sSxZw
# DATA ePwBRm81e92tx+BKOloZX2ZsnXPDnvVx51jEJO6JtyU2Y+kObRE2Vazib8JwJV2r446uK4VXz9VbFw/uq1fTbDmbUTaq2lEK7lLl
# DATA X1/CMnRqJhffXtYWQ+Vot2o0B1kfNCQLLbpw3K32wh0z1p2SPVbpKXqqKk/JfsO1JYVbnyrkkijqaKd8Qxq7H8y8XGErqlTx3FQ5
# DATA pQLwqZyVtLFiJOLqmROimxewxvDT7PYvQcOv/KUonX/JGuc3oHJW5OjoI8Shg10EimrmrMhaC4tcrEIjEVFGaotsDr0DyLvEO+Bh
# DATA usAeTPWYD4Vb5cy6cGNyUpk7ZlgwJzuTc4cLBVfd/6HvNEI6UAz7A+HAQnlmN2TLiTu8owMyAai6HUhhYiU8go8xba3jorgVLFnE
# DATA leIloQzYWlXKkknZREcOvsXV32YRRqfndXUmPq2ji5zR2XI5wPO22OyRy8Yk7XG1So99Bsjh8Hob3ylLQ+6rK4uSSJOwKxcJ+3Z6
# DATA 0RV/2WohSYF1ilw1g/gzt8grCNS8iF/dzwdchwviyWEIfpRyETXcByVHxAir+WhHCxyNifvPM69qe3yx+BrW4/S8yoL05Ze2OKbW
# DATA fGSlslJvXu6/RMhdereQu9KmuFLUepJXVzNO8L5SwJ110eka4tfX7a2QDbAvc55Dpn4PkZni0fqlguTblQ5wE1mvwCZQvqgqayyV
# DATA qr1BraY0eiVfHENKIRoY1tQ/M0e6ZSVxj378scxcwbCNY9ytLr8+h+iC7hy/k5RpTq+nxS5btKLWupJvr6rAdRFU0fonwziKclq/
# DATA pVTn7EY5M56zHfMV+O4xIqugv4KNYFt0YgzjoBE5+Ep8zyWaW+e97YsCg9AxAmkbrDf5HOVIDSPKhXxF5t9dV1x1vdBRuCuQPj9L
# DATA 5CQ+e2prw25brCIZsqrJ1crXJfsAHbi1z+E/eHyZ9n06/OlOktY+w3U+OC5z35VCywFIKmc4KNdX3nAQzf0RMm/fnWa2IvaUCihn
# DATA lmkW4hpmQ6dgEjg8ny7YKc232QySDGwDywQxTK4gVXEQqFh+LK+wQXlAumLrIa52BnMAcXWbX8Qs54jgTklEcveFLgd+BmajVPrV
# DATA L9akdK/2MponSvQy9rDGyJOSGaemK498803+58d5IPCa8RUSFTyW8iddULhYI1xYKI/fkK+eZsZNKkxZ6oaOm4E263ZEq5qls7Li
# DATA c5V13F2/5rB5dVXT6nOtUk2jeF4kU8IAhJRdDe8hkZIuF7MlnRswhFl5gIb5HUW6N2sot1AGyAnHh0RB3qs1HaV80IiAOQvmB/BL
# DATA eVWfw4ZEb1X+iBCqjxix8HccbaHqgyBot+FP0bEczO6nJcf3qzaCXOli8W3N6fi3MjEytMrmcZaVGW+4gUnlxooKBNVOXVfUFqHB
# DATA gkJXbcNFfcg+e9B1R718qFVDL/k5e0zA/IQjUew5pIIo2LgmU1euL+1iy78pIs6IKbyRl1F5ngB9v9mm/yLXrtcvVDdsv9ADPAIV
# DATA TC9j9I7bkqyKL7j1JC1pDh0pKDCIpvQ0rl/OUS6xU6i9vZfWeau1o1qZduaWBV2wQnson+hPNXQgcIEN1l8qmp1Q7E7sH+ftUoEG
# DATA p8gkZ8Bodwrqu7qnL/dPTg+Oj9TAXNmjxj7Rx7j6pFcpJMbRDPVbgVmh5WLOqLOsuQ8y4VxM8N1BjzHiHsMKbTex/VSRCN6sTZU2
# DATA 1HkmpwromgV2CIfI0JRVcVb9u8YUOZwEMbJ+jyUT297VrkjMqDHeyG3Vad4tub3W1HVrHutCw4KPt6WVDjQTF1tv2+Htd/cKIMf1
# DATA Vbm7szZe2brtASdZpXcwxKjudUL2M13sNPWl7ornSTnkFReAWv9Huvgtd4HuWXv7LZuET21bBpD17H7WUXFeIzjVjZDUWm0R9heI
# DATA 7BgwW2Qppnw2hleJb2ENf1LkbRmbqnONpkeYv3QjG5c5mpcNVNYdbxRn/uZNvc6RLtNmTR2gR4pAc1JNXZyk+2UT+J6rv0RTAvu4
# DATA 05HTfcrANd0A4qx19x4qjLNyAtw0LgrprK2/+Gg0XMbTWF124+VuXV31OeiD1Pe6G1T5SdfToM4A6nN/9mHAgjOAXILrJahY8fya
# DATA C21FAWaERBbQNV8qxfmUOJLBLr2Vq26oHmauN0lSwh321JccBrqCAeAFXReWakRFNBcmh8mQSK2gfFF+rcu2T/D++nGi760nhRhz
# DATA jQLiMFQOTCUhIWXiZwzLj5I3O6WaGHibGAVJ5jvWBqqsp6zf0Zmja44bOEUeOUxI8e3HvKedOO222143NdX+1Za7t3RCmumz96qH
# DATA 4qIdQptCmmj3xPih8KZmelKjzDTlNHpL32r7+z85OIUtId9AhO+/eHn29d09JVZWnnzf353SXUtW8Buvb5oth+Mku6JtkKGsN3tA
# DATA 3S96lWQF3c3maQhWCh7Gp/IhC9gy8RKYAl/p56vgkkrswOIPkqZXNPvfhRndz5CAUtRx9wLexPVQCPdFF0T/67KqwvoYOHlNh+sL
# DATA JDjN8mgyT+T2CnOPykc2J7F+V8jVbyI9O5VlzPZ/NM7Fh6K8e0AayEIl066gEgwnR9bmk8U8tjaT7WtwVY+1ngwhEtrwzuuOB9dO
# DATA U6IXdLgeTMvK76XwQDpTtGaXDkDrgOqpYYygVNV61wMFA/I1DO5tTFh6dGsJ/j66OdLUh8HDC7La/IHSBqqagUYkVYsgBBqyJGtL
# DATA 1x0QNXpc/Crj3HrXMeZXOrELHnDJAqX1UlNJE7IMNF31gPVV/mJpxAwSq8WVhwthMG3+/+SQQT719rvP/280mq3GSv5/vfuH/P/v
# DATA 4t/GxsZJjBWq/Gw5owtr4siqjMw53FLLOkCnACaERtA4RGVjtBzbd9Pek+5P6fofkKS/HIo+o3+51R/R5+p5J/svj08Pzo5PDijT
# DATA nU8kSQkY9DdcXoXzWpI+GaeLBZj0T8wFtrpMzMpP+Wub1vexWlnG6a/g5hXunEvT3A+fql6T+wV6uPP4NkSasDXXq8Vilm0/eXIJ
# DATA esJyiB5r3e1Jbo53ziQNOI/qguG48w5e7H6OtQFzZxTEx7N9Xt/sB5sjTsypeM/2d58dHhxhfjrFV1UQZJZmCVU60jcamMy80h+X
# DATA nCvfViK15iJqyWX+4xIFZlWR8nyruTTb1s0UGED9wXiA5bLLTO6Y6p0uKBti9RYWXV7HunOIXkNw+X3L1a9TqDFCgw+5mONBxLco
# DATA 5mMCCq9WZMB0QSqi1SPfK8BwPnBLjXMbatkC5AQW4Sy4zEx1z09Wnj8jS9c0MRV7b9DneA6dS4mzkXtLH5dItFeZKrvZG/dco/fi
# DATA wkYGdJ0vInx5ScXMpLuEna357i046IASE5K5P/Au5ycg3ocqMZpbZA3gSHQVrgW6H4yzlCmFLKtMXD3wexJkcVbL9bp7nYKdE2Sv
# DATA sednVFQPPRLcAZ6povegI/+nmHnLv0fYcTweuZ0V47hwbpwY7uJDnhZg76KgaJSqzGgRHaaM4wmPJFzUkH2jGxWvMq5UbI/PWMe0
# DATA 1Npvr7kN06KtR16ykc4vKXxpLgepcSdyHem6OzRh2sIsLSIrujdz7czPzZcLNx7FL6lDMLTA5Y9RjaySoBuwMpnLjkO9ke9NaNUR
# DATA Ts0WnXu99a+bJOdqkxQQi572snWNjOrqhzt+Pe8KPePikMroJtYk+h3I6iCiNBRQj0H/jcxtLOQ62LHkbm2+nJbPpSQklrnD6V1U
# DATA OYlK3KJhMFvgFcoyXf4RYw3qI4OyMwGFuVWvGsArTh6HGjFbRNCaMlnaj09lkf0FSwJrDM/QxRNHmZ7zOJkkCze70crRzo8NIFkr
# DATA yEvitpFVHyJ3BuuCsy/V3XV8YxVf0+kEN6UZxzbNdG6TeBzxYSKs5w9vbvP7HDWVsbCa34BlizKKEyoAL6RXUpUKAy5NqEuBO0lG
# DATA aqlZYqxc33Y5T5d0A4GaGQxhX5qnXtS3T8vYYHxh5mD+Cpa3b2tEe3eYmvsxde6C46yI7t29MrBsFS/kKplSmPZ1HM8EOLw+ANi2
# DATA 2jf0m6Vx5DcRYrZZX8GFg2JFnNaQlnUqKYGZm+xPnlvrBSfydl8utO6PWe2DEf6XUtHfqkuuukBOkrCXzb5vNb9ynDypCnfbCcUa
# DATA lvXX4Lo3MduJ3BhSLlJg8Kgbaz0T0ZNLFesKci0zEABc1+0HIY9yYGtSVAMYmtS9u5yZEtaKDuwVSLuV3sfFu03VCl0A5wxze89l
# DATA eNaQdBwOrd77WJzO9BJzDOc+TJdTstUcX540cLTTgo1thrd0VT6uize2gSC8B6W8mdfiU2kzO5KVM3K01qqjH04/WP1Wntf8rv7R
# DATA jt7020VFLU+0zBQUAePBzRNtrxeO7MvcAcsTWX88n7uqxhDavb43oOcq6wVc/MFrxL/va/E2gvcRZZvo02eLI4rHMVqYT4Gn+FTG
# DATA tqrY4QyIkJLvpPq7q1WurO58QpVszV32Oe2Ql/STHb/xuDCfpUec6o9FgT9ZHlZTzJrIrMN0OeYL6NCNPb5VKnSyWLc43N+otIeL
# DATA CiC/FdjvbP+GNmiFGJ7q+rt077hisDlKKVW+jXP6g8vY2ubRh5TEZdmDkUG+zGhH2Zdr2iOrtQrcsgJsva4svQe8wUpSu4Vlxamq
# DATA bjujLySz/4O5V/99+H+z35Pj93H1X5q9Rsv1/9Z7nV7jD/7f78j/+6VEVXU+oPA9uciLna7iI0F1a5EKe77P35ur23Kv+7fqvwQr
# DATA 8mWaJW/WeIMt36/Ua7HrT/BBZ1K65SwXe2d28mUorMRovneN9PT7DzJTYtLVcvqa/HsL4OjjYDKMgm3niIJlq1awRkY+QssQKTWW
# DATA +nOPHPHzggoZKuTNoapFcAncNAPLTalucnkzzcdEyax0dstGoQZPVGEWvgxk1UwZw+IWvqe5+ya7WNZ3YWWzytWanGTIFQHoBIHz
# DATA WCiPn8Mc71OG3/23d7/k2t6qkPc/wJ/fvv/5+79+989CmZvvfvPu7/EK+3f/hIXAdSUPgT+zDvrlrqCWyz/tM3XmmZxPfUSZ+bsH
# DATA Z0C1xmUGVHocC5D/5oEZUOI06dZvg/MSpXVfbPsBEWmABMqkwXPiz+YioUCWgq7g5JuEljNcYFBtzFV9lgiXnOiphbjV9KBZgg5K
# DATA pJlzxod7TzmOwj+TK0Vw5/h6OWBLsOnT4HShTDK1s6DTud0Sb3RIFlZD+eHBs4Dv/g+FV67nTlj/zfu/IZLCSu7wCcu/v/8bqgn/
# DATA /r/A43+k8vP/DC/9Cx8ZLCigL8RigUjHENCOAeam7pRlAgomUbeNhBPMJ/Dh7kGY/xsWnv8NEvm7vweqQVh+w2XxsSw9UIpVmB7r
# DATA 3b/7Z5jKz+H7366Fl0gGIKya6AXBfp6D+6I4I0yuOxtZQaq3epS7zbewie82wZpavtl8ix3e1YBz1y5/VsqlY82UA2Z0T0DM6nn7
# DATA LUOpK/9dqMF4mNKKDWYcznRxHi2BOplkPWRTyDnf+5gsS5sbwULAMvzq3b+8/7uCXfyLVU/1PXeuPxIdfywRtxJfzZ4/EW+mpy/c
# DATA ZPfLh06NGe0v3v0jfPnl+7/28Q9+ADKD2d3Lsx5/7MWF2FQBwNvSiisAqHjj2k7oo4q2ffCsYUv9nU977dc0Ub4dgn+Guf/83b/A
# DATA //3iEWtNrJgudyH+TbBxSqaSNcYexlRP2g8FEdm3zNPPN0ycBzbAExGf/x9779rcRnYlCPZn/oqUqtcAVABI8CUVKMjNkmgXxxKl
# DATA ESnb1RQbkQQSJCwQCSMBUjTNCHd7ens6xjvdPbsRO7sR+5jY/boR02W77ba77IjZP6D6C/NL9rzuM28CoKQq9/SW7JKQmfd57rnn
# DATA nnue2XI3vRgiRV+mLbGc2wxUnSFzPE4v4ELXVlXa0/FAyCkP4UO9S6xazJ1wOQV9JDAE5yKH7MUIMZ2IvxBC/JM3/wC//+7N5xFA
# DATA +JeUfuQXlAUEMfGf3vw6+nZ/8sn02HfgLpayWnNgH1eKyFWxIzhQkUP+TBEcVDC1O3fW3mq/CDLgBH4yA0mEBVQMiXJXgTXtTPJs
# DATA n5PQB0lepelzfDN4xiUrv5U2ap1xHgVm+X/QgfgLWSTOqSI5UCJYKN4jsGciahXoYcStuq4UariHNut1ZGnqjDhTOWHnTqZDfJYU
# DATA uLLBMOFbOccPHSpe6IjmrjgnZE4EceloOHLW4+rOHfroeMXIQDRXQhlYifHQ3xQj4vnD2GOHwnz0lnDTNRXmBbckdkEo2XQRVAW2
# DATA IH2cZIcq8z9CAQUxBqRU5dyK8FGxT7N1r9p10arjzICjMDDwnA9Hkh9UV0szIRfEDZRm4tbf5lkYoK/2nnFoBfNmUBy5OMRHTvnz
# DATA Uys2Gc1qjiLZ4TplTg7fuVArKDXMNZPnSgOz/g806j+HifwNsg/A3+VZT3j1GZCVn9I59GsPJMi+Qq0v/sraivjSuRoRvdFhF/u9
# DATA y7b4yUqgMRtn+oGrtTWrRaKY7H+yXYNCIbpnMd6fwUoyaQciXypyXOYBlsZN4B/fs5s96V4oBtH0rHzGvu46M6tV7l7RWVCMxW8+
# DATA C04e5o1r9W+Jr/inCDNtIcmEF797848W34A0KnO0tAs69Atr7shUypZnfP6oREPzftaOj7N0MJ2IMXqpXicTLPqKgS6zAl9+dYaW
# DATA dQgBcguw4gSooAKLM2BwoSEmErAD4CXs5+8J/X8WBQH7y1JwXmoG2UJd49n2GR5imH8MttJfYwY03k436px6RIm75+OO2kU2AQmF
# DATA JihpmYSXp1XYGVU7HeexPFdZhW0IWlEUQx6IhtPQHOZWlXWU4WUZaH7fqdJ5OVCGQRh9kzQodCgkh69nR0c32HxEYDSfgtTwF3g4
# DATA vPk5bjSLgmqa+zneaGhbKham8ELDBxxRx6I4E9bETDrt3JraDQXXtaCdt19euc/8G5j1z/mA/eK/h9+/nrPSJqSTNWQ7ioYy3LRu
# DATA BZ74VbmI2WJO61RRd7X5a/wfcVnxTgbL+m9YMsOb9i1OG5qbzUNZck/josyHo3t8ika8LP+itto+Qz+IHg6AY+t3jAoXJdgZmRpy
# DATA X3LIbhlTjq5TSvP0Ih5mVncwSC9YBugDrqpAqW/7R9ruVcxjG0fXjiWCGrvZkfoVIRzZWshFQXpewBiLsjL+nHbbr3B3FW09xaih
# DATA HUfL6Xkpty5XPgvNxiDbDvMJXEKa6W9PM+HQadOot2oPXYeXNYvPk26Zhfvuit6+ffshjojWBvb5NB4Qpe/KPUWs5IdKtzE5jVFi
# DATA Id5tbOBpqCsqT9wzQQefklyvJh5Rnheg7a9MLIpDvahpSJSiH8+I9WK4itznr7kKbfyFYP+wZYdGmsl1qChd9EBWKobhZAJ+7x2F
# DATA DCYfqb3r/oFyoaJEErbcAgKqIoblJgGiCo+iQusWVBNZK466ApeLybdjdothN2aEefITx7s9mrjfJeGaIvGVZtQ8bK6SkKBcOh6k
# DATA x5wIga8+BfY7fEAuGHbKg8RND87WvIPT5VVywbGk0aUwg4lIq9g4fTTIixuzan8QNs1nWPj+7k9BDgOjt9Q+8myUPXMSxXzITbbi
# DATA HAblBszJV5vBmy2HHC9aJXmknUICTJYqcsQ2x4qwROfs+3SvncQnsy2etEJ0sfaMjL30h8hF7orbZpVUVnyLTYtEnYsWVpatb5sG
# DATA XTn8cn2WNgeQxJI48yK59gfcBKu2g1bVSsxrLRnH/0PXYf0ul49dRoVbRQ+qGQ6O4qdQzwnVw8nY2RzRikgkYv0Zzfk52uXZRgdl
# DATA Tuz2p4TlPuCUeDIAt5DRqg8ZtXvzh4snRqSKiF2aIuXOXr9tpgGFLQsrziae/WH9eIpRWwqaz5LCdtRNzYeMvsIqwOSaDuWzVyFs
# DATA qnZAQ7ZtLQgoIscr9Uk7Kj9SRhSMikT1K3Nsj/kw2r/M4Eaz8xrud423tJh0shn9Qez/Njcbm3c9/++V9Y21r+3/viL7v4NxPMx4
# DATA U8KFlnNgwUGG3kuZeGigNCEZww3WOHsDnULOOZ1OuCzFFYEiaPEeD7LFU7910tHluyd165/A4It8xVUyt/EAmWqOLeO+QzNr1L1S
# DATA j/KOxhyZciRIqeKv6ZB+u0nicKty5pUhHIUTdPzC7Uz35DZJy4CbMvFeJDAMEGM1GU7KZnnAe/nMkLjQDz23gYAonJ0t0gA+g12u
# DATA fCngfEb4A7fYQfFU9EQTAOZqDaUzUo/tqNuPT4YpsM4dlmoAd0yBZSZplJ2mFxoViIwRKhC/OpWRsIMb4YRot6Ey65boUzVKR4x/
# DATA js+khGgkEHIWL/u2otLcuAIGrtMyBp51ziWkP86MI+dDYxG5AdqD/LnYh/wjqurcZCZqZpzvYG56nvwI/m+4DvwjytByHZGSDw1R
# DATA XMO1YOIelTBIBTSi4ZTz49FgQjtBihnZzkkqVt9t1DM1YEYDioYTLLH+3DesgAvXm9+75hM4ZmUVrImUWEBYvBRuoHa/a4eFzdkr
# DATA 5jl1i8liUSUnGGRmLulKN9K2Iw433m/YRzwkBbEn4BafYgn4qGS3y3SDYLlEVVEHFnjMKlrhJA3GPtMNc6qr5CaZYYDJsswBQ9oF
# DATA tFAOBgVnwapaZ7SEhLlRwYBDw7JmspRrGj7l2oZ3duPOYorcuuxdxhbA3v8AePb3hHFkjKD6xuoKQfNYUrGJlqFw/hwJzmaQBtIi
# DATA 2UX7XARNDobaKBlLMFJNhyp6XJeFV9Y3cy/loGPqcf7s/1fcl2Rj8TnLNyIgLCiV+C2bZBlBDAk6yBjw52SyQNYJtNXJOjW/Ras8
# DATA wiqa18ivEsZ9hFtzqcnfDkvIgezLS23oIlEc26dwDKlTQ/sXoeTdzR1p2X5JYYB9JRdGhL7RSzjX0Q9YznmuRHK55jJHtec3bMas
# DATA bPOQ0LonEzRQxyGSRBPAzkOc0a/UmQIUlNwbn0dwOF+k465+hqN8/sr9rbHQ/HObHXOFZ2RP9zmu6Bc/gd9kU0c2NfSINJkWEg4+
# DATA sYRGQdYXf0VCrH8sPvB0aBTDIpXLOHay/lfLVJXpIS7gL2C8MHYc/uyN45MzE5jdCbZQtBQSv0FFd4ECoudSvvPkctFOhudlvORJ
# DATA OlDbYf9VcilvddMhO/d4AoNHW/dx6c/K32wmr3FFDqOXk6MPK99EPDDGu9Ci2OPi5zut+p0/LtlkFBNwJnhtLkurHDUBvf3qTzy6
# DATA ih84zA6GHdbl2Qklajdx+EhDWhoVVWO9QXyStajJGRIKaR//UbkVVWpFitf+Yb4D+eQE74PqAvDROH19yRdqHoezSavRq/6w2yp1
# DATA 4m73smT4PA3b8jfv37ISldVrRxUXuNwcw7f8zVxZkZni7QV1pMROStYbTUPKfkrYYTocpBQQkysuudFBkIOYDs0yDEPrINOTJdDA
# DATA 37XVzGpU6heZymHLD6wUBm6MEUEZhBo7U8BNy7GiU5tOMASBclb5s/LL7A7F0x2TQPhl9mGlfPhnW4Cr5a1KLtCVpV/h+Uh6JPoH
# DATA 9hItAIOOX61SpCD+vXbEGBeSSQErRqfhimUCM7Qd1P1sqYSHluc8Oo2ilob9X/NhjljCz7lzmAR84MSBsnadjAUGQ7xv6arEvi3c
# DATA CL6S36qlK9VSPr6+a66N/s49Ntu2R8L1AyqsIZ3vAlBugvbbFfHt1JTrPUYj/1DrbCShLpSvRDX/5bWn2iM4qvg2lP81jzt2vqLM
# DATA ub0Ips4/ef4THirocYInxC+Igfgl8grEJHxOl4Ff8JvPkJv4PWk/PgOO4m/g7T/RoTNO0OoyYQqyhUfWr7gV+o+sI9n4E5kM8+WL
# DATA f1cqDs6jE3hhgIFqZDkJ5vg0PpL0RdQ4XCMBbJn7lN6S8Fo4TGxcZyvIJUHNZQzIX8boKNP6fxqe3eQh9HVEMd/Ey7uZz1XCObYl
# DATA RRN1Qd3nUlrgr+L9rzK5c1g47yKIb6NvRCvp3bt3izug0K7X9orA6FWurm5f2ZTq9RDq0bRhHVi1pTBUDktEeEneb51CcN5TGBaU
# DATA uBMjWTXxvU1qnalYVVAJ5pqxojgKUbizWTxlPmSLbvOQfznB6A4NrpF0wgwIbwRUAfVGk1O2U89zsBxnhYDMJxgHPPN4lyOdrZtF
# DATA MMT89MfpkG7EDFG4N0w4v2cW4IgKDCcFTsjgQXUN+EPFwOOSkHbZ8DpDRezkMqNEUPaIfPCrDyVLUUFLSY4AuWXlsSC/hkMxcf6P
# DATA XKPZxbg8a2ujuy8P30qrHDAj5UJqhxq+3rs2B2p+EB2cJnDiZpNIYR3upng6OU3Hfdh1/fNEXBmGyQUOakvYWc5PwHK2EYbCm6Rp
# DATA Pop3T4nD+sOiIVCIuXH/hCLftdztRQuiqZ7lKsDrXrXomq9XCswfD14axGGtcSQ5zIUJLmKomfHUXDT0qIYa5JQddVCQzlh3AdPS
# DATA FXTT5HW7dgM1meUvRlGb/Hkx77jOoVP+iMzcsFmTUrxLGkaSyko8Jf3SzaxqRWMryUbioENwYP4AsL5Gbi1GQiKviQGU0EnyCjaH
# DATA 555iGjE7SKXUtfYUdtcrVSV9hxqlojioPcbtKEDnydCdXiaCc4xajiCaE/9aZm+uBlOE12UsquYqGuzSnZIx7lPBl/rAC41H6UD0
# DATA y/QOFqBGcvepGCw4gcps2YuyswtEgTqUlKNKLFGN7liyFmCvBv0OCbvF49r9TqZA+4pMUoEjr08inXnya5uU8VxtenukRUYUHUgb
# DATA DM6g4irUjRJiKuUo+jvRglnyGKxqOSiqfg6VDdFxmg7Kduwc+c2T3p/wKmjCISk8FLQRVYipIeLdjFT3VK1JiiHgZ5IR/igzGmGy
# DATA IMUBKWcnoUd+Bf7s4/lYhtDUkzETzmTG2bXFa+AgkRgKA42PJnaZoq6MG4LW3/LZQI+bobM/t7OQBzB8zsJVhCTUpO/65dmglB9f
# DATA eUYDlEiqPnmNm4GVJjRvMr3xS+SzjM/QqATmYSYoJA3BqeUGCarE8iJ7JU1zhfdVVH+1zxI4Kx1pvpa9GaaDVZpl9cUk59ENOEws
# DATA KUaMfPaWjmCAeR1MFS1cRlkgEhJ1JhNVGqTTbm8QU0Cm0kkHMbayoLbpF+zpT2I6dCbXESJ+RzZifx8dPN7HK9Zv+UKEjnDmBgQ9
# DATA dbWMVZQVC+hDBOtO4zHLJ+boQxhGQd0GQqnsUIyAOBpbZZk8tWSVsvI0kYWjj7J+eXWgWaXNGWck5jSxnBbHkDwzgWaEFz+mAOkA
# DATA gVHWMmFH7Gtmz/glPuZG+LuAXknrBIOgXPLsW4xw2gKA3eiLMYUmPCzB3A9Xjm42llxvNpRxrR7xNPNtyUqyZBy3ipR08xYjMFnI
# DATA sgBMZk3Q2ka8QC5YDvM1jhxgzB6U3u7zN+t/ND6aYbHHTN1IPXrzn0iU/leoWEEz0N+TwumXYuDKiiclt8cYH59TVX4v9OE/y8vf
# DATA aKdXBolH+uAlSQTwIy9TSUHB0MuWhoZLGENmsHlg/D9k+foXNhDY+JV8WTnczRc/e/Mr1iigT50M+DjuvJqOLF0gv2B1pOytmhPE
# DATA ZE6+La6fy2yOtM6keDPiBOJA6LSjkE4cRElx2ESvmjbBLAGQ4A38XY3Uzm+aM6ogCeI1hfNH4qwfmbFoAisID6NTDH/UhB98ClLE
# DATA Cp6IDIsfKkyYkl4PKBxeD1uiL3Q25a3wxpKIqXmSTShxpYfuUEUFglIw44GtqVP+NRaL7PLFMFevhOUk77HIUFZ0BCQLmcXAPMRi
# DATA LLLxBGqH4uwkjGbweqJBKWkxVePK7iTfp4od/BrLEK2osVB+duQjnk3Y4oDLcfBJbFd4i0Ixi9mO2rmoGrWtfd+D+85pWdke69FX
# DATA /SOyOkOU46+VtuxnPXibkb/lslUK3OEmaXZ4cdDDDny2nEspttTiIzQ1URTOUb76w3qWTCSoZbkk4VD5Cub6P5EiBp2QqHIznASQ
# DATA PvIO4neliieroxKOrI7r6PwTqJxkbWZJd+dQ5VwWNsKR5fN4vDzoH5tAQMtAp0tFTkN5Cv1/aW5RU2aO4PMzdj74e7Yh0u4KKszC
# DATA m98A5f73cEyRFB5eA/8Jh9f/ZmuB+az6Jbk42MfgZ0pzDH//e9tvmGCsLlVXJbRGRyJz3KcYpCWJ7c+kz+xJ2O2dZIy5KKCMwL9Z
# DATA CBqiuXG3jQnwFF9n+dfrLNBtjS6HggSzF3S28NybDDk5MQJYqdyWFdUVhHTmnMOXlSN7ugF0up49pAB6z5ojOuRZuHlkJeaCu6YN
# DATA KKfhPED11N39UoDNQLvcwHDogyRdGh8keaEdeAjYFXMbUxgkcNURfvx6KnsE3VfMx0NukNy+ZAEVj07HgV1SmgDW0rFCDEZwD171
# DATA XMUYbsIv/pL0Yp+jnY3iKtmrCHnE3735OW/V31BMpN+hz59s6S1Wi/1OQqD8jJlENuYogLUTIf71pdkF8+j3oaaiR8EmDlfZv8wR
# DATA 32i45c6JbjfpPsPqJB3FXeqVYIEQdOuyCFj6cI6QrRpZZ0q/d+PjtWDxntuaSvHf8nSaKiLS/8C3eI9hp8gSZP6YvwZ8vghh/bWE
# DATA vHF9zzgUDKITByr7nTFFDcw8NGH/iyLRVL3yVkJEqnrtL7sSxFlMwVtLE9VtDlsWeaxBKiG0Xq9ULMevsvHxkhnlSOMl/TKsX1vU
# DATA x/bZVGbjjDpKHucwgxbPuhTUV+g+jDifGleOgJrrIvuxGfO2zHEsVbdu3gneWuVrjRG4lRZnbJVMl1Qs3fz+J/FtmPuVPGYGQbiN
# DATA Q0fsgGvg3OAddetV6VvPn+4dtHf2HrUfPX2yvbuHB7AtrrEm9Wx7b+exKaa+mEMUBQqcdckyOYSXHnxY+4p2g5TQfKZI5qjiHG3Y
# DATA g3tM6EnnpRci4vB5QxrlrdaishIXZoel/Rcft5+9+Pjx7kMFCtURWbzk7elcf+JZeuXDISsgNFwO3Ysgsb9DuqbSkXQRnyeBlHlH
# DATA WjVt0ocG0DCAOJYQKog3umD+RHGOnMJzxQxojoH3W6NSCBGOlt4CW77K5boKYFVzBk5dO/pWmVQelZ8olxYfn4NgMKXRHqAAC2jt
# DATA WCJjgg9YxufNpXfvY/5CfRkUxjXA0/0XDVK0PSKbOjokERg9VQiVuH5IKSWllnKMmgpzzpp1NQIykBBLDMsq/5EWnlub1nOXZlJm
# DATA GWZIm9c62HmM6e0s2qCF0kU7lM8uXYPbYZFnK7Ll63yR1EwHl8EBktpn9skYTydpLsn2u0vq7HYL1Vh2bDyZlimog7R7qixqWM1t
# DATA EZUW3Z6KZFmq45Ya8WL6LzT7+0zM1D8v0H595kYg/uVWQVgrbTPo2hKq8CeIyApbiSdq0d+WxKzlCCCAQxKNI/9DjBpK0lq+XC0f
# DATA HiQZYyogoKmC5K2yQ+/szVCZg7aaPMzsZt/Cq6xVqoqNZyGVNYSkIgH8/V1VqLWzm3nGcbRFoJUfIWDhQ9VkK9cJqXWJ1W/JQD0l
# DATA HnU9ew621T5RtyKgEDX0ARMi1RWvQTVGagDuPFLVI1sECVufaFtllEsYyLpzigLKUYLplwB7+udA4OixUmg+EJCGwS9Hsb2w2tHX
# DATA i7KGpF3kMxZyzuIqeX8l3ZBYu+rnWUavuiTLwmNz+ytgB6QcXUHJ12VyKX0XntcVtkQjtbdnT862zm09JfcKIw67M6q8JY8wr6G3
# DATA YxeKoBe6kRQxAvYyHhm/BRnlbEsPU9O/uCww11utBcYfMMfnXo16n1+44gjp1XMyC1jpv6J7rKc1srpQD5WlcMilMM/NDbtctxrT
# DATA 27Hdc4y5jWA6xJzPX4yZrPsH0WNynGEP9WmmcinzOZFFo+kxzCh68fwxzBbjB3L4Q/F/YTdQgPAYM8UtJh1guyaMyz1OBhxWbygk
# DATA QJCXVbiFxr1SbY5XbmHQsiLRlzTrhSUZdkdwttj00cYI1Zad7/j5zpO97e9tf3enzXIKAJ2XLNy6/9OyqE4qjuMhUIYFZ1SE6jIj
# DATA 8tXUv2+sFJaas/XC+UJHXmKEhbZUoBm8lIZA2nQdShUMfYrqp2fAc4PR7IZO1SGPan3k6UYLnKuDBFZXytOfMC03FY7y57XXGh0k
# DATA qDbX3i1iCGkG9kGkM4dpU2DK6Qk7vD82ZuXCFLOf0uuJyiuG+UyZDhjLdd0OSoPZLgTFqvp1TQc2cGwzKa0Gm2ZWQnBWU70Y9zH7
# DATA lmrNU37bsW7Z6NgzzrY9DWwj7bl2yZKNeSk/Fj3JEl1FxNkffztmkqFi2i2aY3JJjs0kE/xQ4HcCaiywqnJ22nMlyyG1mlqYbudh
# DATA gj23OyEm1q5X8T1HwmbOvspBSfO1jT6z/GEZN3GySn5j2WJUXPdCkfsT400AqUYBh8JiU2w9AZG2+5oEliwzqPEWLl+PQsFBsxBZ
# DATA FoTLGcajodBIm6x3khps0nFiW7d3E5X9Gx6Op/1BV5wCppyeeIi6qhken3fKh6Val8GuwMTWM9wkqa1LZNDOUUwdwPoAyp22RdAK
# DATA cm98iMfdy1nW6IL3wE3gtrDz/ok5V3HkBMZ5NrY64lsYgnyQMDyxzaRbw2b5Pia2WLmwAQtvpiLdjHfxsMieZYIt9l9k5fTuRPDt
# DATA CBslBgZEACJjo6GS16ndZuHEoEsxJmkePp34mGfElrI2lMpSb1l7tlCcQpVBVsW0D0TNsWmqooXShDRace7elhOY6+2UYxe1zY/R
# DATA m3EDARdRmYb48ImLwlHeetK0W58OyWD+rJ8h09xOX3nN5V313aODm6lajqDi++kNwviEVtX4yLtTZ7uZc3641pJm97Tc/RI43Fh9
# DATA yYeZeOMCFrVJxLb4ts31irzjJRKTOV1aln/OTlGu4QXESfpjxW9Fi0rm7eMgCXdOQ3JtoV3kdqGcp3BaMgFLYCXODq+SS9vL4YaU
# DATA zgTCscxLNRwXkMv+72KcrISqyoDsV2TwgHYI/9YRrH75u81cw3Ke0LLBbI9r1zFaCswWRKkObrX8bb2ofU8uWpcRQpNVN3z+WSSS
# DATA 7d8ac7ufkxEHWXW/+XU9spOSKOPvP+dmvvipZRPiCLXfesM4EUE1HonWg+QyLMv3SJofR1QEvXUUnLVHcV8dVjkpOB045mWV/XS5
# DATA sON3OE+S6927OW6nCWZXEJmzeAFNKM5KREH2OGygb1Yn1tfD6NCXDAO/5F3D6qzNLlcCgbpF7zoRSd+VAnnTW4FqZMNADCTprLVe
# DATA V+qWNRrUAJjaJTE8jV3iOsfRLb5tVfByvkNp1+oAlB20szrR96/g8aRGRdxNVfNbyXB6RgbELhNUKWA/VYiAW+piE97KeQYmyIgJ
# DATA g6LYMBpawPmZW8r5IVTmgMZwQqxgsTmgqqtovWlT79aG5gvddnK3Z9fOy2H8jiSOhs2YFXft06ZQSW7e4/hyM54xCf6EHCn/Byck
# DATA xc1pS1JN79gJTU7dfpUyyOGmXa/QpntkB4db8T1Jr4Oe/SKF0ls0T2aaRf74ImsKOdwVRlMgRsiu6HjeudW0GrTYQZ9b8meqBQ8e
# DATA YP1ywWY58CkJMu1xFmiOimCjWyENtjy8Bajcqu8GLNXWewPX/H02i3Eu8uRfUCpUyfMX2syypcwJm8F7q0QBQOtluouq26kjBqE8
# DATA nCTMJTkcNWf/sOPPY/R+JadbTiadZSq1bMwzqUzcjUcTibvgGW6Gb2oL3vs5ajsF6SWPmgwglCugv9Ql1CM9lK3jyXZO0ryTcFeV
# DATA 9wVHvui7134sNik58aQCd8lKgL3QbJNPu4IMRoh3sAxKFxTG5FpqD+LLdEpGy86RmCfaC2J2jnAXnpFBHr0P97Klxbao8LcfQ/0d
# DATA +gk0zbrFObIx93KnY+RqorhQkNx39CxXOXULvSoNDjeDUUe8BQkFXPB8L7VvZs5Ru7KQjcT78YEmUZc3MmDynyjufhFLMzaeqoo7
# DATA 6ZN4ZDPz84I6VK7d9GZkE837srmIiMQl0Lc0gVZ+NSERihvd0RObqtC/cqHT+HBkwdEKyOoYcbu0DV6US8vxqL+MIZOWOaBHiTVq
# DATA 2AcvxrJyjB6hzyFbx1oh3+skMm/z17L3jaj2J0AxB/DtSoUH6iZxV+Ja0RY9SwEQ6bDfKaPgtbEqSdlOMZ5TrsB9Xb1ZnIaDErrx
# DATA kDifG9l6YFtAr1oblGcCiC1ALpT1wvKG8FfGZT20lrSAVbRWLaeyBACHKx2n3Us3ho8aKSe/stKEIbSKo0Z5EdewXctDLfCVcU/1
# DATA hjtmVulDU1Kwtp89TuFc2+Y0h1gfPVJmRJkKpmf7HSVdxsRsOhYvmyCqCOY/xajov5NE938RUconNEv8rQ6kO2MNhPDbqQzqnxwc
# DATA PJsl5OA4Y+yeB4zbOMnHriYDDTiNoFSEkYhLWfTixe6jus/VSMB4stoAJpf7R8Eabt71lfXKLLKwOPKFJ11+ui+JV+x0LA4oYBp2
# DATA 7gKjWcqMQTxtyWyQJKPyqpxOYREewnU/kggLv/NcsLxU5H8hy/sP8Pvv3nwu7ni/hGf2mQ0F7/8MJX9OGIff6niWKoQfK6feQcl1
# DATA y2Iu5st5/yfjYfbLL/76i7/LR9zE2ZUCssL88VLM7Gid21fG7fSzEcaqpbQ/Jk44JeQB+ipZKlpKVmoBiqXyVJD1IpycyZZY0huU
# DATA qS25eY7chtUoS4GB6+ZnN6HB5mgdGEEWbAIVEDU+zC0DU6OVsZphyFH4kMqXkj9Oj8zNm8YaCq2gUMHubB2tUtBas6Hccr30hvnk
# DATA 0Mbph1Pgnbq2musrTfMGXF9Ns3qm3UUt8I8qActi7LbWJ97RxCbCVS154mORDTthzoOjRObLmBgvmPTNRT21sFZflPNKxf3yU6L5
# DATA CdB4JvIglwuVPU07NlSK0Z8dHBRK2Whko5eFUnawM76k9zrDycAha46+ytuDzCoyMqS4bdKMmTmy4UEWr82xnssloOIwFPS/zOpP
# DATA 2w+f72wfRD/mh+ePvvdc/d57+q2njx8//V6VY+yabphfzOq9LnVgeoUZXXDOX+zBPRRpNvUefijjX1V58/jpw++0d77vsiIuBQ04
# DATA GuUy3dk3zHlrq+6K1SgZZmjjF2edfr8lljooYB9OWquVBXJckk6mfzKcntGCc16o+v7utw92nj+pRub5kxfPbBt7fs//lLkBHdz9
# DATA TruJKaVQX4iJ1gKHH1PJpaKMcZpvUanjQonicindjAbKC9aQcGNldWg+tHMtSU/e0V5RDhlv/pNhXzSDqnmZnDo3GFZA2IHPKC6B
# DATA BCn4B/K5wXAGvyXn9J9QyiTkiD7j4B/soPP7N7+mOCB/9PWffx5/zuLxj46BHH1pyf/m5v9bW1u/u+nm/1u5e3dz8+v8f1/Fnw9u
# DATA LU+z8fJxf7icDM+j0SWcosO1pdu3bz+HyzqQEUIPuA5uP9vlmAxkfUiXxCyanI7T6clpyOIfys/KAYgCeCReSAi7OpMe3BLpqiaP
# DATA kgb73bMD3jgfoDNWL0egnfWPxiB0WI2B7jBweMDFzGTZU4onvmjpW4zmrGHScuXTSXtE0A3MyNkIw6D2u/DBzoPBOnriK8Qm3lhX
# DATA LtkWabOzD5EjmM6x2s/iyeQykJfOnUHpCdutRZY1PjQ77sfHAzGdTYcUjDnmQHU6LSFnpzODlCHJ0tfl3zJPm44+njkfYP3haDpR
# DATA HzV499LnCYtAfQke3uHVNxHkydTYeJq/tKU4puft0aUAmKERirO7sAJn2QmAH7YDoHwVQ7FDH3Phgx3r9uHHDyhT3BZuHNouPbaN
# DATA J1EK+iOYyWyP+maE7XZ/2J+02zIylgOmrwARSk6YASPX5JuZdg7BsTr2qJKNSdmEXbGAVXv9XmsJjvEmQd2Km6DKTU/FOZz4p8rh
# DATA FDSS8mD0At7FBgYmoahJXFWNdNuq5VJ4Pq2W8skmc3Ezej3Rxurd+gr8r4GTpXw/WAYfms2GnYO6eMTPk7N0IrQuU5fHiARFvLRx
# DATA xImE9vc/iSbTIc4MNwOWKNn28INendaSftGC8grqHEzLeB2gD24twUOyEfp+7Vvp+CIed5Nu7dk4RbOsyCyn/RV+4TcDgWuGnQkQ
# DATA uwCAJE7ktTugheTq1gZFLt7sP3vbaZ9qupmjjFaMHzFYu7oMiL2s49ZAcZ8tuGx3kLzihC0/o2Ux+Lhzx4bjtY1LZjFcXJCyh6Vt
# DATA Ts3wI3HrRFnWxwlcXseccVNX9zPA+LaFJCMvzBwglcr+hhbzRqxMdBHBwmtiXbvoa6UuZSvheTzklEG1A4l15gLqde3i4oIi5Nd0
# DATA rxzIzvSYh6yjisX0WEChEa3G6OJTXrPCDeBO/fbOgWjLGpUFbAkBUfIY9tzCHoQPKogIdRCALfxLk+2WJt+O/35e3E43aQuv+cZO
# DATA B4JSv6zP07+4ualc7cfaqtJ9WCqQIg0IBsCThirRg8ivO08x4RMvZOHUaDBjCNxvxydJgSmMHMtOKgYeScjQ8kb6CG1pwxxEUJEw
# DATA SyHlbie7RQ+/vJaRxq2vflSNNlZW8a81/Gv9moophL0frYa7trUGQENUhUrh6ufcLOctDCFz1Iv7g6TbpBND5/E1k1DWqDkQKLlD
# DATA UB1SjQ4YeUPKkRnA+4NDBaoME0pNLoDZQg0VKsTPYkxG/ezp/gFiBdlkGcAwK42Dg9vd2cjJ9xfMrFQm188eIPrECdOvEqR1J3V1
# DATA Y6GUIF7TVSyA734Evdenk05IQlbYWD9LOR0JN1ZXmeFKf4pH74crK82VFc9fRrJeTn6EQu+wm4mVGJDKqla5Tis4YCeDWj3OVImy
# DATA X7puxlwx45WhwqD/1FJhDc8xHTqyj8Du/HAad5GnSycxpRNroW973B+yiFsbX+LNzzniJaUDtiKZb4UdtXyj5S4zBqhOBwNKTlge
# DATA l6wEkbWjq7Xq2uZ1iVNfzeXhXyiWt5smfFj3+hPi3rsJSuVZsMxw8BBznEBFcq6wMrS0z+IRMSh8J0IGZfvhwe53d0hSDzevY8zj
# DATA C28f7e5vf/x45xHxYf0zuE/S68e7T3YP+G3yeoRqC3y78/1nu8/5bTpsn3J8ctPEtXZ20bATSwkdNdWMbi5Ehq+G6cVQyQUi1dIS
# DATA +5GfYTgx6KdLaY540cX0Bk7jNhXgoEErmLTZKYHV2pNx3Ov1O6qMvawr0f0Wd4E/PlpZudv46KPVjfW76ysffdRQtxYqRSMIFJo3
# DATA u90h2QZGMgrOzQlcg15EtMI8uSTeLDCzNmLvpK2K8SRKw5Tflyr16WgEvLCVx1na0zeUvaft5zv7QH1hLR9tf4r/fG9n5zv475On
# DATA ewef4I9Pd7af25eVooXKoLd0jJas1H1khsXmKfEYN52VitMeEZ4C1JGtJdSzN+Pc0u2oQKFULTpOOin60uqC9jaQoPWMcYcIyUOF
# DATA kkdHNraa1zQgjd1G7+F3/nSv/cnTx4+w/cssUntgK6INx9sVz7WuCMv1DW6cnPeTC0NHDIFi5a2mUVSdVtt2hP/TZJzCARoPswjd
# DATA +mjDiie8TSrq0c7r03iakXlxp8Pxds/gOeIOItngdeeCi8j8oOV3qjccQLPhm2kInAmnDIVR5OM67H5CC6MLzbBu5W5rvM+c+5NC
# DATA kVs2jnimTf6SPVewZaBHlMhKVd4ycR+i3nQypaUaJheY0pqMKo1cyb5eh1DVKAZx2DNw6EWGBjEcrRsYmuhHsLhbwC9P4FrPQzyL
# DATA LyPodchnQTwgl+UoGyHDr2hHfEKmhm5i7CtzbDXFElahuEpIpWn7Nl5gDZ/B+4E/oZGfQ9DltVLyrAKxqzVWa2uNg9W15sZH8P8/
# DATA zXmAl2Skj3E1P0Y3OehPSLjzbV8RjqYGLCrn6QjbRfo4jAf7eK5TJA9kVykvB9oPlem8r1RyMWpKlnYQ7Wv1TIAUSli5UujkYulz
# DATA tx1PSjk27VB93eY8ez7srLpWEoc+efybHuQdj+FK5Y8wxBTThZIAEkth+t2r0vkgyUjiMhmnP2Ale3Yad9MLDHqdWdMwzdyEfI9Q
# DATA stNJB01rLwjLRVJXiafB0mc7+ZfUA66LApVXlY8lequVzajZUIAeX8DCodypbE1FSfrMBJ+pN1TSnqpXPMtMUdcrXo1NJ9BleObz
# DATA Ozv3BSXwltKHqhVJVUmzrPgZygL+aLMl2npsRgzpihytpAwGam4PaqTubpCkrRZplTHeI94GbvtcAp/WVhcZ8zM1Vi2PdVhVm00V
# DATA twf4SazqOJEcHC7plK3EU3QTmqqMb/5ShUe2l0Z5FLYlu3ZocovrtxiO6XGxVNvwspa9TRu+K+JRqXN6UiNOVUGs4CfmIPXxZOa1
# DATA obFZ3VzHewN0V1lkYWzvVBbjKnlfHGWnqCZCjGCZ8SA5iTuXAaNMAWB+eUrUBOEdudRNj/PXt6o+2bQpF8wsyeQmhrqZYTfpymw+
# DATA iB7qpYmAKQJkmZCIUhlIRck5zOHiNOH2z0hyQydwjCFc0KoIORi5kNP9kSlRPxl0ict0rmxm4+TJiks5iJqq2Zrzsho6wIpOrqMl
# DATA Kw0w0hselUOSdM5fhgtrERSaoXkfcjXqK0Wz9e/bBHy6tOrQrMHje5sSK96yTyjdrl0kp7YzbQNw+idDOo6uMoAsY4Ir2sicJDQZ
# DATA m8ZQwB29eYKHOMXWc/J344lnRhisdERESw3LOJko8tPGTsvxqO9cvRWZhPdKqlsm6RO6Y6FhP6mZl48vawp3yA3AoQnIkmmnoLiX
# DATA oGLMqAmMWZ+t+rRtv7WWNJwqXeUTp+zEbT5jeB5WVqVj3FrKnyIjOTPxi6jfIc0OJvliXQbC0pzRaa+XJZaYfKUaNdgKwm1UhceZ
# DATA C6tvcostJTnkRwoI8w1i7vQXbt492IjHDQctoU8c8+6wRE9ushbnAyE31cjb3mNBI8KhVD5eEvUZVJXAL8YHKoggXOZIEU0rtMXS
# DATA QPUyjij2VgT37n7aLXn+YmjNKsEDD2U0R3lHvrzIqcIRj3w1UfG4H01ZWZIIK8Zdk8saQAU15jAG2SmePB67QXPMcmgclS2Ghc5O
# DATA m9le1aJBoBLkeEpL4o75GJjiV/mkrhZAcJhWMw9CrRSJU5RlpZo2r5E5+a12b+WGF250h5qQOygKvRNUTolMg6zHnQC5Yt9U456V
# DATA 0/eVTK6pdqsgbpPHcO3mqMUiKurUdOjZkJMTFpuaTiej6aRSkA23SJ/M1jB6yCQNwDU4Rl0ytHOcojUNtlYqyFDndE55rs+V4k+X
# DATA lSgEdgbEKieRV4GHgGR6IQr6Pau+PSnEiHh4Wba+wlmA7VcWEalKOnvUE1ziRcYBgHLWyuqdUxhQ2SKy1tAEnVpoK8Hz5zdtbe1g
# DATA c75WMedEQv27ZW7DYSIfvtg/aG8/220fPP3Ozh4S1+cqaxLZQLF6ONL5TpSIuOU09WT7+Z9+vL3XfrG/83xv+wmJX5TMNO4C8wQt
# DATA aJMeK+uMZuPDzT3b3t//3tPnj+zmVBUckwUcbVQgj/rIQA5Nnxk0lmUqqreFiCfUT/tO19S9XYtWns5X5AnQ4bfNDUlScmIMyEnU
# DATA CMCCB1dfWIkaV8EACOZ4Piz1PU7DvowgGhr+p9Vic2JVo00NGsaH26/MFwNzdS5vblS0X7Ada0YlgwY4V5dNUPduC4lpfHT0trP+
# DATA j6zAWlXWVGbCLBwallUdU9THDKfBUXyJitqqLdp1tS8B4MhLI+9UFtnqTgZ3C7yW+Vpf9kpwV5d5POtFVY3J4v2PcuFPdWN+Em58
# DATA UJcWVUg3WVn47LUoAYGSwz6xpr/b7/USCvPEN4ItzgoMMMOzBDhe7zQm032dtVCGQttCYF9SwIeX6qftxtEMTteKMqv0uO40XJc3
# DATA ZUZejdCAo9CinJojpDJD9ja4z1BwykRKgBLNsz93R6hkj0qHIiSawVq6Ljyg7bin5ljmHVHi0SPQ6Ae8IUR9Qml/fMy9VkI91Cv1
# DATA hFFoRleGybhG7jDuXsJLuMGSL+P08LZakNucnmSqQghgcSXb5eDyHWBPuOqcaiiog2N7kkn3PPzKdckeIglvyCpQyAYHs4cmmlrx
# DATA bzJP6DOZ25pHw56NExjByelE683tExHu68w816PnpPmIzDK4Pjzd8WUbmB7fz6P0CFYP3msHNFbMMxnMbx3Ln1MRbmz8EggrzpmN
# DATA OksPbdNiUuZPTmGT4NC+SZgeQQU85ki/cJlkOV+i0kNE0EHxfEuVLXswwn2gYF6kwyohs15w9YLBSE8mmQOFQZB1ty9qRAwinZBe
# DATA yMTRllJjB8hiMV03ke5m01o3Ca8XxS54qSs0t/I4qALmgTeroci5ZoSWubgZ7u2DaNvYJqF+BfjfQQrHrciYIh14gy3QyZAYg1IM
# DATA O7AuaJULNDs6Bga1O7jkO2A92JHjCvzuIA6DWV171ekln2cdXsVb+aHMl6XZ6GbbR/weJ7j/RnqfT1IDj6AfOaK61oKYzI75OZFY
# DATA +gZDV02bPTOz8ZDJ3PyjW9324RjqJGbaRHbUee0E5QnhXsEhqSYge/woeFwKLxw4Hq3TO3DAiTBUjjjuqvA03P9ke3Vjc//Fk32y
# DATA a+HENOIGUc9OY/hYHnmRLU+T193+CW5PEvNEdHiMOKsZPL8cllgdRBwwyeOtm9vJID0ul+4I6a9U3DOUKXJXTjEB021BodtHeNTZ
# DATA J6NdSL/nYsqszSnDL7GAOXX8tZh70MVjklmz+msrssBNcqWMup7Ca9S+C+sl5xRwfrxN0y5tqlLQ6/mtHJ5zHrTMD6FBbcn3Ot4K
# DATA FLfITrBOQS/uVWqhnlhysGgHdHWp4dVF+VGT5ZzkV2814IYe6oS4tNoZ+0gbL2fb9kvJDk1j1uei4QB7UuMoVjFZCbZKHIFqAlMo
# DATA BUdySWqCUOmCLtRNqCY3oVm1lWN00CcaMa1BUnL3DoivNlZWLP6BrTfLJQPsZtT4rz/5HzfQDpDvm1qnGLjT6UQD4qw712l2ni/r
# DATA De8ilsMrmQ//q/2ne48o/G7hVYUJztvdOPRbTWTg4Oq8Yq6S+EuU27CVXt1Sc1kEgLoHbhjjQUITLXGHgm4rxf65jX8JbqwUXa4H
# DATA 2/4iHgy+JC/Q2f6fq/C/Ndf/s9ForH7t//kH9v98ejGM0iEw0xMKHtRNopNpPO5GpK/Yil4lyYi8nHCDwRlynE4pQOgIaygbqHPY
# DATA kFh8lidofyT5n97dzXN6LJEHtbdncjbCDb20dICGgJFKpYXS3DahPs2ptPT86dMDJU/nQJC6XI0CHqotAvT3xd6uVzYjotCVf4uq
# DATA 1lXEo4qlTLiDJLrKFEvk8OS94oTeYyWsnl1dkfYq0zhxdcHkOtJEJx6hrVybz3Z+OSNLGPdOfxs3l7UVNc5hMrlIx68cK3pt0qaX
# DATA r94ftZ2SGCxw3O9MbPm2MV1HDr7/epBQcJCViALa0od+1j6Df4F1zCbu6yll2iJOzecK7Rhc25EU64hr4e4zbAfgN0wmtklDyVHz
# DATA cOJb7EuvDyq8UWkCjcBkstM2IhVA/Xjc7wLDrZ13OaCdmjw9CzeB5UkGT2w36n51M5Xox9HV6uq1owyTLw+izXWlZUEmqzyqKHFh
# DATA n9OFaWZihH9tbmysbRgun1uZBSMlpcMNTKVdnZyaIAyksXpPjWS2lUy9iXYy1cYGmskccyrCYxyNC63Z43mUdl7hPZ6qKFu2+Kw/
# DATA IFvO/miT3NBKzRLrbU2Uv/6o5GqGeqUrrngdZYih0RUVv0bDW3QOFMaHjXFbUbnU7/foynRF9ydkSPn2ZfvWWbOyllRNkPOuRLoL
# DATA 4mLko8qHamNcr1Qqsfa3j5h5RTTqOrq6WkIrAWgF+DX05oQ3xGpTsbZQEbhSDWLgNmW7bkXX10sRpRMVxgeb4WpAAVGGcpqmiikC
# DATA ficdo4FPrbECTDKqGC9l1FtQS4Hi9iC9La/hbWeiw7byYnXH6QjeXzHMUSo26YyiLlFeGPKVgeFZPELmriqYWbmG0ZqGTa0/MXPO
# DATA d5uQqryfnSbdqkr911GqQzbmxsNHVzxLJnE0WCfbMyBT55u1fucM9gf8db7JkIFRDru1YdI/OT1Ox3BHA0Cg/av9Mu6iBoXejQHQ
# DATA iXqDUwCEBLCOWBm9urFx086dW94QrtWwgMcozhrFsA8mtUma1o77J0yUa0rbTXknYX1wLNABVDhz4MnrYvChx27ABRihvs7BiQVW
# DATA /61X6kr24bU9ePg/7A8TwK2DUh59KRfCigR0SWxFlaNYLiBCCahc++HTvb2dhwe7T/fYY0isAR2yZxohc4l1DnihX6LVIJxD3f4J
# DATA VrQuLzgYstHAS4xbPhQtCGkIxQ9Fsx84ykvEgmXIg8HpwOm7DnCEky4gHA8Uy4eTWTr0mHbRy+6HJUqKGEyy5QwWCylIHOrR5uIt
# DATA WrzHvv7p+xJqyaoiecazhPTANNUuEXjOS0bHJbk4ScRpRktyhhr3YbVbcg7gxx96ADEr17cN+WypvB2CtLBvSd+JjuHQkOrDAxzn
# DATA oMlEos9I9VQyj9iG4saqhiCg5IhSXUeQrvNI6jKMOhevi22Rl2XE+6OmsaJz2x+W9kiDQDd7gZgcN8djitzGpXa7paPDZmNVrbLi
# DATA e/ggY8qseRvNAnGOTDqmAIoDfY5bKmAC7rA3YW81DhhAFRi+Cb6gs03xuS5DqFqq84DIVZeSDRQ1m5XchqyKPo/xnEOzKEl6PGQW
# DATA ipY8gra5ObVH42EWKxpS7pW6Cdku5Y/olxwBOjRwYmblrEd2gECm5TFqOrUO/d2jv0vC8lv9V/I1ZpSV/FF4dF70h930ooxO6/Jb
# DATA 2/du0yHS1bOGUbL/QGeQossN2ffCrB7C2XacEpOJNz+MABHJjo864xiIusnU+5YrH1ywWc0ttOJvt+rWTgAg7aVReoF2tXzX7aPZ
# DATA CAXdR40L3K/YLkTd6DI47/qDAQcJnQmUjEDhgaSkuZ3SYvAh2wSztCH7Y8sp7cXoZBzTXoo4zYjMidSVaJaiwq3wJieThEnGGBup
# DATA 1EZ1O0RrETaW3biCmPEgYrNWi629MTv70oopwe3CWiDjhSN022audgYfabdVye8u3unkV8ubYs5ilYi3vUeuztelMFkLLpTdKUDp
# DATA 7XoUGOHPxsYZj0FRATuAruf1Tv4Qs4wT7QvZ86THybzJCNEyP+x1qyRWSccxmSAqEUv97BUKP0aoW2pRVyr3Ot/0W6U64V8tFDzY
# DATA i1/Z65q4ldi2F7cSe+N58gz1V201qAeYi5SZZsYR3hQykYMpLNPAzYGWZuxLIvnidD2fSchUTkdTwsvth4KBuUID6BHFUTmTyzK9
# DATA 1Unr4Iicmfidi+MmLiNX054Cz35LRC3eJ/Jz/QaAamV1tTITLV4M0cReKIlvtEmt+umuPDNTSy5StRhFw9/L3hzQa1cC40lfRFOZ
# DATA nPfTafaObAiuLzGsJAhcjko0w/oIY8WqV05GKRQCGhM9rM4SCWjGdXQr3nQLQNhKNAMkHO872F6TWyUtMAr9OKmhjaJWSsP8+K4D
# DATA +492U2DuJORsU3jbdrtid1kpqOxAyZKdXEmo5GYkq1mCu84zEj01eWWvc20ikPGyVjp8MexPjpYeWepWY5VLsmmR+9DQl7bRZqQl
# DATA WwsVeHVx2RO+W86cpY/Jc7JF4kbyMJFyS4eSvv5oCZVaLQAjZl5f2nmddPbRL7ilheYiMI9myYyXFUBVgpwl9nmmYaIqqXUJPOLh
# DATA LnMaR0vfi1EZ9fFlYGClkpvWvFximXNnQkGou3Fylg5rcOdGe6NZJZOh2hnzpdWWmUTuMmDfFwOx2RXyVXVApD5xI4WJBHWxInsl
# DATA QvN5uXOLDU3s8zEX0MidoCItciUUT0V+VcTxO8fGoHtIZKIgPkt+9TgCyCKLEiBhi2BEUTUrVP6XGPCd7yuOAYCJx807Q+YORwH/
# DATA QvJfElaohryBfqBby5zY6kxxbhSzXN3/Wrp3X0ktZ5LErSZSdri6SibblSKLx5Tu/gkcwWUyXlyZEfa59DxNQ2qKXAxyvNIBY4UB
# DATA PqBGje8txpooPk9R7oKRvZeRfkNPmMA+7ozTzFxrxuYyl2M6vgJGQHV7YzblrceG8LBisatjiwKwv1X8dY935UjqYe7VjrjeI7PF
# DATA gojrAWz0E1P4ySkM/+gGwHcQmveY2wiLbJ2EPaHDvODwX4SbKzg/eB9J4lveqkdVW6/CQt4PVW5czS8cVYycqjJjzhzxv4ByeEeP
# DATA LT3JgV43MSc7+3un53molTzTTjxgFjoOF2cWLHPqp5YshMlydytKJ6dwKKgpCK+uTWm0ofV8syOxNPo6CPsf2v6Hskt+eRHgZ9r/
# DATA NFYadxsbnv3Pyurdja/tf76KPwVGOXE2YcMb4pFfTyzbG3lzRgkmdNz0Dkr0tN1NMh4P04Io7qeTs8ENTX3gHjodJ8/SrP+6wPIn
# DATA 6QDDpbvHAyMQ+50iti8tPdw+2H789NvtZ9sHnyg7HnPFpbwsSLPKJb032p0YmKX0BO/ElaUn299vqzY+/vRgZx8a8SKzUpkn23u7
# DATA 39rZP9CFGptr9/jTwc6TZ4+3+e0mv9rfPdhpU9pG8w4fde2Nxqrd+s73d/cPdve+revAd/eDqri5HhicLvVo5xmB4d7S/gGMqI3e
# DATA qmhrUaeDiigDh/f9V09fPN/bfhwoULO0EVKYOJpAU8RmLT3febiz++xAFzAtcaZ1aeTp40ft/YMXH0OR49L9W3C9ILExItCD+/h3
# DATA NICzpnU7Gd5+cJ8U7nD4jDH6we3ppFe7B28n/ckgeSC3+fvL/Hh/pN4gm22M1O4vjx7cX6bmUV68+2hn72D3W7s7z0kSRUlrMM3P
# DATA uHQY1350dMh2L7Wjq5Xq+t3rlxjy8pOd7wfK9qDY0dXmOpchv+LCUmurXGrn+wc7e/u7T/f2yTupjqMie4oOB20CENE/2TnZTlOq
# DATA T35NN6xS/bWUv0iOYav2e8D7la51jPl9ADZzy4ZxzuciaI/i/jijFKOZb/d1dW3HVKmqEBpDUjYGI6tw1ZD8y4ym9OjFs8e7DxER
# DATA 0Wq4/Z2dT/PRbzD2ihOZyIl7o8aOkCijeqISMHJ2zYvZfo4cKirBUNz4T71LJszlEuFWXntk8c/cXnqMMf8Zhm00tWjxb1fH/mLY
# DATA 15bRYXvpavQ86UzHmbF7LkweZOC4u/fd7ce7jwiKKjQuJ7oQ8BCJ8zQEXqQOY8VXcUzO3EBVjXt0Vyu9fElGWX7CCX9gL/b2t7+1
# DATA 097e3985IBJcMhJYpMY2obfl+5h8UglT4+MsHUwnCcvF0XCPBPh4b2Q0lJAVSg3BJnUbvmZ9rk3bkW3eRhv9I7JuwyaDenr8wFEX
# DATA 67T56pxOAV/X4bqT4eFShm/Byt4wyt9swlH749F4+ON4+vrHw+ngx0AvDhswrB8PRhP6UYFCL+v1O5VvyqjQi6O+m/f+6skolBBY
# DATA QUXEc3VORFbHxKdwa1NR2QwRqrzFijq5RgTrOInbzfHOWVbBvQfR6sbaAlvg0dMn27t7IbWTJmYSd1lihcH6qPj5pX53GMOj2vuU
# DATA lwyeBVD2TrY38k12qBqevUcVwrOzFNmk8nRnmWIKzgJK2EfTZuNafSEsgaPOFhQU/iEjJSxrSLcKoFZHR7GbAj5Io1FOI8JYLaex
# DATA TZ8VUaBc93aOU45SE6IGuOlcLFdIjldQ3VIdMO3UMV8qwmtizCy0RsB04mEXg+nRgXd4Z4zOp1nSLVt6T7SlwcejGREbKHh3y7RW
# DATA H7Cwy3dixATne+nkW2hiH/ChzcVJlAiw9f327v7jve+UsR8lQCMgnQCzNAGyiR8opBqzv/iufzzlSGorFZS1vV63PZOCcCIA7X/6
# DATA 5PHu3ndcCbgB060WL4EK66CH92j3uTu8OZ3Zi7K99xDY66fP3U7Laca+j5R0Eo8SDtpb3GVQlWqXUEJHPXzvo276uwffrywCre89
# DATA 3yVNZMEUDNxaFtyMaBe4VhTwvDs0aTB7Tw/aUHHnIYzj0xsPhCRW9LrsDOX5zrfzeKdekLwKkaKx8AihvRePt5/TdcclKTguRVBU
# DATA mCOTLZkpiE1pjGwst5X1Rj7konfsDW0H5BMSZHauUry602mfxa+StoZXWZenaEYbG8W7hQiVaT5Hrah1mpTVZi7YnQMadyg8QQtJ
# DATA SI7d5rkKPwWnGD97Ku3iiAIEL0vyT+3PEJrCXjVLVmcXa12RDoV2r9viHrmd/ErK/Ci9Cr8ne+xiBLCErGx01FKi/qd7jz+NfqzJ
# DATA Y4oRR4zYn4li7vPHu3vbzz+ljyGFQJtzvlLP1B0FWTlm/QBwHEl8ZmAisXxpQD06DLhEHenzMC1XcuFtnQ3H1Z0tZ16ZTee+Jx/U
# DATA B6H44uHdSFIJChNuEQu5KMloaS3YKt7Jb8PBHObNTqyx6e6mBkYGMGbM/SGcW+4U7GfKz9Eecli5MvWqa+knrqQfdZ0ZLAHN/+En
# DATA 23vf3nnkEiEcLGDin3jSMblFmz3V9JBYW0k5OjF1hN3SR5gZ1CVG1HHzv1jKxjBC05Om8b46a6k4U7HhlBTyhs3Z/bsFTImZr8NG
# DATA 0wup2DntkymL6WM8kcb1hjeDqfjkgrQ35aICziyopxDDpdGvqBkUD7zl+V8U2+ImLAAvsRlc2DItCAwhhj7N0dH9UG35Hul9IdY4
# DATA /VbmJ/gqoM8eI/xxnCUBK5OF0cMYOwQi93rwtr4424EPKd5nOb1w8NiSNUHZkJIkl0NCKRM3iA8zW1BdN7ecapSTQDsX0dxtYZHb
# DATA KFM2afPJ7v7+7t6383dSZ7ja1U7G7QvITF6gl+OXJJR8aWtQ2SwUxb+qW5RV4XPuiOMIhpyRgUQoXFdLB6SAkbBgRyQa4g+UaUPe
# DATA 4vk355RT91cHJo/gX2v0Awx5SRFxuY9DkjfxsJp2dPHkNQaQyNipIM4mbHpSlvqyL0vJuR9k3pOJmGbqmOGvSk09TOkzyaLIpNov
# DATA VhdRifiOwmn7HqaO55vMRWbRxuH7fXv5qkbjMlakBZBq72Es4/iCbJBfT7TExhbPhoWs+5fDSfw6KFudE1HvJmMMyHNInBNfIFOT
# DATA 28KL7k2b8RKmi0Xd2HCBQI3l0RwMHHdFMhHm6hbqFih/akxeCn28+l9rbMJCh+r7ke+C7H71NtZCkFIsVHqRiZD9UMZwVDATLCrx
# DATA onMiafxGEmlHw/aWQwqoOaB9uiNCN875WM6P0QM2vBFYS7x7VEOx34HJgoIx5voDgX/u1Mr3gfG2yGDGEpMalZUtGlRlqZh+MnK9
# DATA UH9KyOj1iaoXt0v1ts7C04oS0qr3iOxn8ev+2fSsyLMN+0rH3TJq72ABMc8l3czhUQAuLWllk2qQM5kocGLwIcxI4kJ1bXOlclSp
# DATA vAWxscOF98UgHaHHy3Q0g1pTCQsJ8POawlP6qBHV6H1vMkKq4IQzH3R1cho3yjnzK5b5LfUfNsBlrVAwkCC+rHeA/8KuyhQBXTrN
# DATA h3iXzgyilF6+Xlkhsawah2CJPPrEW1FIowBfgK2eCSCZRenqiqXS19fOcBRjT7O0NDWkdq0sytNz020gPA93MA3ZznN0Oz7Y+f6B
# DATA NxKGHHnhenB1RZml/rCbvOZRKKUMoyICdX1lPfwpSD2uSvExes8qTTI9LVsdXHMYqYydlwVNF5LPPd/51y8wBSFwqt/e2Tfs45It
# DATA FsoEO7ldx9QRgzhPVHTyinZU0OjrvlH3kaGnLCS0VcI6SUem28SbdL200GyQ3YZ1e/x4F1VfefWzpqBHTBAK1Rsery9FDq+AhDU1
# DATA VbOzkpRnnQ+Va/sU8m4TzOjBfj4y4jAyr+TDiLRuOQ0+AqyptoDh1q0tUiVjizqMIkZ2gJrh7J0JmxhWNGnIbRq2iZfWl/LKpRxd
# DATA EstPm8QqKlXRObQQV7QOcD7ZoJ60aYKosRSs+Hyens1qcHb9t+Djnu/sIV2w2bgQ7vDykfWRhju6lWEwBVlIfo38n2hVZZltnspD
# DATA E52XRlpShMPlaQJKl+/sPf3eHlNWxVm5g7fwLTtUzR9p1NMKv8thxxaEWbKuVkDWtZiMYrb4ivHsJvKwoNw5KLkgQRJOKSRwyAls
# DATA 5gltbN8UZtlzQpsbSLO/99yerGPTvvP9h4+/dDG3iH7QFr5A2C3CXwmDihcS/1NvMM1Oy473JsM7JzcWEEqyei9UFWGoHchHLAyS
# DATA YYZRskipz6bXbH/eBnqskmRkCQZbgWXKWuVSFYlys8SBflCckLt1yjigwlm/E/DDLVg526OWsNYyQ7QM7QhUFNKBAkDiX+tligAr
# DATA yhGGpeXZ6kEkIL6dIXlbfPvNERMu4nk7228rVFu2trXLs3Gn7exd2EjZpF2wnQ01qtufQi7Aps8CRV+R56/6EBT+OwB/f/o36XKO
# DATA 3s0amEAvLLaEnYZ3v1Qp1PCnJkH44Oku+FKYTgKQkp2odRcYr3rctQLFqCxTK0zs4EjhCCOH0hHc5BhWp+jQJN+b7i1ojAFkR0Qm
# DATA pUB9lI7KFQ/hVVnXU8I5Rhwdy5yTKreC3H7hhik8s7jel3pqwdcxpz2FBjLSH4+t84gS/1hPflY0mVl+6tJuM2h9hh+JyS0sZQvJ
# DATA GDEqmPc4YOyMwida4gdR3pa5WWjbFGbIDp7v5NWZ/p7CgHIcRGOZZ0ILFJ4C65i4FGmZoOYgvVB+dVnIycfsEOCb+ueJOgbUc3uS
# DATA 8h6sx1mbcK9cKQLgbEMXWsx3sf8p0trkXY7cidGKqohI5ZLxy6vqWVeK66utrOoLl0RYgCrmcM3wWbKgzqlAISjq8oCpfS2UGu09
# DATA IaGhjh+2nKEUluaY8IBIXvj44va/DGOI0J93MZAI/bmB0UTB2r5HQ4pb7vKQ3YJ60R+mtAUdOwa7BjxWmnNtMxcxSyjehyrbessb
# DATA +cxqfODqyvPHeCx+trZByBncUTFS6WbVtFSZb4oq60Mtzu/4XQFktk59OkKzqjJ1PL+SgWyN5bwL1GMhlQZQ40te/MXMbwoG+pVb
# DATA 37zP2eeOH4qsYk6e/HQEB6zkGpU5V/tCtukGhgrCIXskW1/ilIhM2CM3+YeWsaC7tCdk0fbSdvggx4o65PXvseuOutG2t8t7u7kh
# DATA BtuSezyRsfFdX4Yb+qbHXX5LTear/pAlqSKJImEqiaKMno2SRSdJXt/2drpP85o6p5e+3zde4kt+d4EpHpqBL6Lh86vk3Eu0hJAK
# DATA CiA4B7X7KqDM4QIikDWwz01B67ecCgE9V2EftBrefD/Z+X5+olRuIRcEtk0/MOJKI3kW/qg/jJwB5xVjIaVYQMdOzc0cPJW4kSLS
# DATA HvkChoZ44GB2n2Q0SC8xCEpIami+wl1G+2k6HPBZPH5FB8VxCIFr5w0VTs8VJNnyS24iZ5dEGXgyz4ch7xfhmfMmGEGa2iOU5d83
# DATA 1QjiVPP5oZ4lYwqbMCdBVPDY+fjF/qd5Ow/nVm/ztnY4kVlMdUBGF4KQLY0YTkp5cIjX81l23hlPcl/5NTnkAs9iHURV9ekxYMbH
# DATA jx9+p2pb8BbfqnLxaZyrhRX5xO7KiX8CcLGe9z7OLZbEI34Pi6StLG9uWgljoRAX5UHSQ387zELmHrSYPQYpMaacsa3WSnDATl+X
# DATA 8icsbT2OTtM/FikwO9TXHz56/LjMmeOnWdImx3orukdvOlQBaxVKSRMcPgkQJJ6sljj5vBbR6Vo5GWJuQKpoPR6f0IhQGidj67Qp
# DATA 95N+QoON9sh6MefzFL4fub1giBr08W45jeTlowh7uh/ij7aS9aqvvCb4mX61A0JU1WPZaYAYYxHp4wfaYZWq04xbir6oYqsUNnwl
# DATA FJeVxCMSqbxrzQ9WjRfVKOeoADqR0vv6zt7T/U/3q5E8EU3TT0+f7T092H/x7Nn1jDXkjSGbp9whE1WU/ME5qt8YFQpGeTGZi02A
# DATA ekd6rb4bTFSHi5Ut0REL2+kkA5LhsD3FDopXtjFoO8ta9k2aisU3WWCPzN1chbtn7g4Kzmb74OmT3YdtpQCG87b9Ym/7u9u7j9EE
# DATA 3Lbj+Uq226JbLrfteNlZMMMJ1/2tZyMMFrPzaRYojvRW9Jq0t5kY8so+yzfqlrZxTao0/Lhrxnly1nbMr+rcbaRDURUe0KTLIqYy
# DATA tM2W8kfs2+ETq7cEcrZSwNuNok+6pVPF++vUVipur4omGRy1o40Caou9dBWf2uyECYXl3o/jERMLX9VgGlOjXI5K3FtWwt+aKcXr
# DATA nENvVH8tqxGTToizuHuNZ6JYUKWNxYd8X9BZ+OPth9958ayNQdRmOT9jwL5xnlkPiwBUDOIhkDu0FiODKatuThMdFA2M4wt1zS64
# DATA Izi3AxMRxjP1mHXzz8eiVUEGnIDGOkCtMVjqJMBpOQgUjzunqBdoFskfpACM1Y4pM0Mi8R5kCmaAWoRQlVB5X7UsQeLl5EQKcqk3
# DATA A6UW8hhXFBFjdjAG91orm9gxlDq0L+p5cYQCCIHsyNn22pE4Jx2Q0vPFA1KwUllcQsA7tmRzMgazzC5wLsnseuCjoV24YHMES1cC
# DATA oZs1wnq0AC39nay/SO5gNDnySWyLEfIIYOZxXUK+XKFqvgvrfPBEeMYfISS5YJfIMZrVJM5mt06RajRJXyXAQqaDLub2vqhyEMiq
# DATA HFFOejxZhxBpWzKheAuGzt7HVtcOm2cdESYMaTc5R5haddyPC91KGcYkD/t0/2DnicUDKvRwugBkKVtxstAEiEBkmTV4Dt7SDHma
# DATA 2xHwZ62kJcYJo7R2MgmWdGmwllprItqMGoqONmfSs3yyQpuYNQOUTFHiJqFMvjrjfjN6l61kByhnnkidTwrP2FjGOUNLFxcX7HaG
# DATA SAhkK4ypWAA+3Mz3WA5ED76EF/BbtpDwSxhVWLKW29gO32FcAjZMjHSBqc5hwzkgxDL77wGCXqtqUWRvl3hz4wudU0ybhGhsorNZ
# DATA md56MfbuRKvzIKhr2Np2Za/nrJwd8I4NMoMhhJgn6vWH/ey0iJ45clC5QVhWrskxIr/PfRHmWBaR8UmuiGMcSCVClMHKkbAIRcl1
# DATA HZQ+uhSVzm3GfplNRV2NrU9qICQmgRYCbsAkfVDlqgo0vvxxsQG0ML3GhfWFIDSjcy3akyaqDPVKwFuZb0TuQRNMnabxr+Jb6km2
# DATA ND8A+zxU4mZ+ADtkSLZyhThriySleF79pz68tQZQGqgWbMd3Z7uZnLl0TKiWEKyqRZ80J27IyfvjyRdQ29FgPSaVIj7mtVhctBLm
# DATA 3a3JUvc+3Q5x7vlLdIibXpChD8eQ8zl8XIWjaqQfeBECLH8QWrh4CzD0VKzwEsGLvPAtQorrXoO+Ul5oNUMl7TidJTVv1eZNbhwH
# DATA z7f39rc5HyWDWsVhDynEzaWGuNLC25N7dZCGWPS5yLnhIubSTZjRQFXr2DEsojlZ5p56yWvM10ZejRYeLFlWjnlkl1DxfPHEfaMa
# DATA ecd1aS8iHpl3EelMxyTDar0TDyV6onN1OmGfzrlXlWez/BWlmMR0Elhe25PgOCthcOauoWr4+j5p9rs+TsoDQhYDd87kiJBpqQHM
# DATA FfszXF1Wl9MfWURnaRYjMkuWZGOHwwbcQEQgbXU17DVnowWshcTJkgOP+yfkwOVuLbfqkqsUz8+LW6nMRvob3vbNHjtJHD5OLS9C
# DATA HZ81IIJ6EH0jkpnat6HwGN9inIZtdHupRv4G8Fnp8DbB+4Y3S6ngYXXx3A1aBq7XNFTTaYDHJf42wIxaI/UDwRWyozlVPfev23QR
# DATA 9waDtChQNb8fZtCianDL0JwJ7ja6zQG8tUQzJDw3mUpgAjYJpAEudqqIbubh0+/uPP8U3cC/9Xj34UGpMotu6enO3175aeVXMr84
# DATA rOssIFl6t+sxoamFqjyXWs6c8Fd5NkqBW/rAcTbmjFNsoTingbPJ50gCm16crQwvMXOLijTClBbxZ6WQ+bGVdQRfvyc1Armu2RpC
# DATA fynk0ncldxARGqnjM4S7Rr4TlU6SYTImlISKap94ch9tqdjUDJu2XZzDjFyrWzJckif9eMAe0mq3OmY48rLYD02bZIS9vm7im6xl
# DATA DjdxT1YDfE++XsGMqjd372L1hz4gxM0fTa5Cjlu9/picTIaYF0pK+PYSSs9PRQv9Q/1F8WuaiIh2UAy8Nua7nm19nTOQ8Vy3uLtF
# DATA XbdC7iPvGHA5Hyr3AesEHc+SW2xuq7JkVBacaE6a5yw4ck8WfHOOUSLf0mRxRlMhl7DFRuQomosG5sydhHrqKSeM06Ot5oPjVd51
# DATA BiF34UX8AGbZGGIgtWR8HrLldUPwKZmBf6i6usWlAmCIkLKSb9By0ZXDAL9MMVdrSQ8OZWwq3VczEv95y7GPD46ANuT9HQf+gSPv
# DATA 9MllHxmS8lBialg3KD++Rqs0BqKZnpF/CPmcq+AA1kXNVkHOjMSB3uMocJSmNG06TtNBwBReDcKIxfQrtgLgoekbd9AhQEcKWVge
# DATA hSF8dvZ1YDmzZo7BjqNwM3vDiHICJuZyGTOlFxVdG/fvnPQaoBISXDsu6Axu4+cireGzzxnoQrO4CpswBfcnlbKv8q1iy6icbohj
# DATA JOKILVbOuYksWfpqv1fmRYrM/5UD1Hki4p9FlFV6UKqef1mxgByk3guQDI6wkaMY+u4VdOeyyYUenesw49IEq5D1/sgmE1YReXd0
# DATA 7ft62Aj11gi0GBLdSOwYOAdC14zALMIi1GK2efHBs7QugL/MZTGI8CsKh6+cDopc3zC7rn0PrC5WS3v6zWAeqn51/cVx/yscwExU
# DATA Cd3z8Z1EXnKA8TagnhHoiaNtU6plNCPud6Fiv9fH5J3ImJhHiQClhl+ejyQm3iZypvjGaq7Vyp/jFSPIzJKBkuuXFzzvPXrD578k
# DATA /avzFMsyUw5Jpo/MlnVkUi31xbm5qxEFw2HdOCSWHTDSiYul+rHiYhnf/lcJchB+XJ+c/j9wws60AvB5WN9MSIREXjqKmwaO5PT0
# DATA 5O+Nw1yOcuEx5OTignU/RokdvIhK6I59u1YTFGt93R2vBOgwkeSuZG537Bg/OiU9FcQC9fHJID0ul+6UKpXrKsbiaw3is+NuTMWa
# DATA fiaxqsoSwp4CIUmsHyFlmIjYK2+sM8MYyvFfbWokNZ6sTcW5ht2exaOxqQL9eUSuKPSmI2ybjwfXRb2LOZZteeEQSseoR0OowLJn
# DATA EdFc0LLHUUNoKc2tgAXIoq7ltqz7pmaMbUc/ab3KZRO0uSehet2SxSUGzxYicCWV2j3EbAXs6oqYryLkc3irwJwMV6UgZTNVKroh
# DATA ZSLPX8W4YFULDtumt8LbVzBYer52sZVBoPjC96Zv7+ztPN+21MVf6tXpbW8XRotvjYhLVTy/CSlqeYXYnaqgzwvaR6jGyAnnRt4T
# DATA pUUvNmhZVHiPrDhXxlnlwvZPswL2aDuB9rOdvUduvFujzSjggW8iuMkrLgIIS/Nb0CZCWlponga/A6RQ1NHM5hRr3EOGiAwXzy7E
# DATA ma8urBSCeG6rd2gtyz2qib2TrlvoUbftrUvQUl+uxdz5fCsc449kd+EvkvvZXi01Z/9y4I3Y6W8uN2m8sRY9wgRpjJ6x6o1B2+Y7
# DATA m372ucb131Eo4AoEPDA6FwsPaAVmydSmc8qZKdsiAwoGnTvaSP4HLOy5m8cS+MUxGUJxnvX69vhkisB+Rl/KVqDnVmmXD/DoeDrs
# DATA wjEeAfmLBxESWXVcZEQY0+kkIrihXAtzIuCYs7pOqIstY4zxdiydlUu1mh13DeWSrWdaTFBUg7nNmWWsOCsAhBggo4WoM+sx9Gpj
# DATA NupcbDzCAeHx0mGAMTMxAcSZ3RvC6C2qCdosPEBFnmsWEqlzmAKsST36B2tmhDCVYJpq/FzHgef2P2/g/JWfTCmomgw8Z5RDH50s
# DATA jkbdD19Cx4tfRrGh6llE4DP1bjJt9pY1cIW5/HAKg8kiCzuJKAZBWdW4r1EBR+HhaQ5ODsvpAqDqQKtaCAT5EhSV5rX48+FsYLYY
# DATA vHzgSP3YgLAbTYdwN0NIIspg09MMqGoBTByNSBAmSjVCD0Y1YaPALKiMxn3YElbgZe56kcjLldzRsTJPjRWIC5IbwFWJSsihQr/x
# DATA 0p8fD/DFeM9tYZyBbALX+XFuQA0g+Xq76oQzKGozSVaskP16px4thbWoThMYyB8vrhR9qN0mQVa7javRbosVAg4N+NtJmc4cANgf
# DATA 3fwPniq0/kp2WB9d/tF7/rMCfzbX1+lf+OP8u9porK2v3VXv+H2jcffuxh9FK3/0FfyZYuwI6P6P/v/5x8+9dnWbxVO3m43qbWI1
# DATA bjcPr273u7ebt4mxmwB9gK1yu3qbslTA6zd/+8VPvvjLN7/+4i/e/PLNb774iy9++sVP3vzn6M2voze/h1+/++LP4R28efM5/nrz
# DATA 2ZvfQWWL4cEm/k/4/Ks3fw+Ff1JQqxrBv38JPfzTF/8Oirz5LX6CTqEoNPkb7A3+/xt4+9svfgbD+Cn8+zdQkVuE4r/74q/h4y/e
# DATA /LoO3ZMI63bz6rbKoQKDuH+rm1IYCEp68eDly+F9/BENgMNqvXx5OxnCXw/unyZx98H9s2QSU4aiLJngR5Ke0Xf6gpsWX5/3kwsM
# DATA iwQ/lQQNX1/0u5PTVhe4yk5So4eq0gTUMmD2klbDtHU6mYxqSN/PsepDbqW2j3nL+pPL2rN00O9ceh0IE1bLxp3oZSlLBr2Xpa2I
# DATA Qe6/nFwOEu9d/+zEeUOmcs2tKD3+ASy/fBrCoYWFj+MsqcFYrFcYlKXGbJZ5m4eOhQTe+Lej8342Ja53khyn6auI0tUAl3tyineS
# DATA UzhITtNBN6OjcHIKnHEMx2KUnSHjzJcJTKgcobQb3sOxdBYlcYbqiUmKh2I92p9Mu5dUNx13+0MMuySRZIGhQ5b6DANC0qgJ1R88
# DATA Q9E2sjc9tB6Jfhz962k/mUTn6QBYv/vLXOg+2euMkwFOo9/hmcFwe/i8HGeAL9kyvq9n5yf4jXhKLHsGzS/Dyw9fnw2oV7slWqXs
# DATA NEkmofZwCeqdLLthNdLzqWq8FBhCP1fkB1gCGftk/OD+MheEH7QTcJtguj9CERICYXWbVFDrsFkG0CSN6VV/ZI/mAzy+sNA+fMDV
# DATA ETy4vxzzbsNerfrHeLFwpmNUe9iMuyrQxjA+Bx6lH9cG8TGD5QnyTfC6fxIL8mEPBe09PU/GuI+pLatUBvjTTzJdbn8U4waO5L1f
# DATA HFFQl32O+HiRjl/R2lDRZRiPABUnzKxhF6sq+NyX1EwGFCPU9WANpkyNBwenMSzhCHli7dAGKA6/gVcb1qH5xoP7IyiWRFgXtsdl
# DATA dBqfw4/0HKW7mPnvlDYApnKkz7gaxGYipqb1COrCtZnM4YATh902wS12mU5x6bCyElSprQu9jh7c7/bPzbiZNGQ+ZhxPJxNvw7hL
# DATA 8TEwmaqb4wTuvRhvVwDttYLqwXTYhV3ttLfIoi3DWBHPGdoBsMsLBvrqg6fjaNSHgU1HACQgLb0pACVNBwjuVQT3w3jQmZI6sjdI
# DATA iftPYrbvjojaR91xfIEUB+36EMKwXho5om6a8FJ2kwlGK4QbBPCuU9xbMHDU+1LgGgpk1EmBRe+jEJyhfhP80/NdRoR7cL8HrDxi
# DATA 4sjdUYBdNihQ6su3BGzX5I6C9qDgA7X2zlBMIjKss02U/Rvx2WgL+fXzuHOJA4r+y6+iG42fV02NehmJEu4nOcvh0Dfdfn3af33a
# DATA zzvtGS3f4pB/z2f82x3x80/4/4YO+Pd8vi90vN/sdP9KDnfGSHv6+kD/57ODiODPPzuB0qdZok7QbXVssjgPeqTTXZ2f9pSRr4nN
# DATA NNOeOEDC3AGtSKwiSyQg6PTHdPiSAM8DBIGHWBp1BGckThsk8ZhC+Z/BoQ2YNajSAQyT6J8l3eh42h9McAZIHzOeMoz0RYZViNtS
# DATA 41MzwB7Mid5R/EDmMwTMDqTDwWU92p0oHq6Deb7xxEfAwbFFkmaj1lasQNzFE4bEizREXJQasQW417OM4hhF+0nyKvoh4Aoaaynl
# DATA wmkyGJGsCgcZxb0erhIyJHEvmVzqGX6aTsfmjJapAaeTRePpULOax2jslIzr0Y4kGkKQ4jymI+RWkM9UWIg4nhEPAwUwhUKKTBKQ
# DATA hwzLxIPLSb9D3A3MLRlPUMd/AlOI0f5CmbZhW53TpPOKRJ6k2iGxpzOY//qT/yWTuaKUl+yCsk46gnaIn7TWrB49xPWPSC9PES9g
# DATA Ypc4c2kLa+BQz7GL5AxWqqcaJYkr7PW4D7RokFSJD8QsJsgoM2yHZuSwJya02FAHSmiIROQYIIg1evAovRgym4eAZMuyDmAMWqx5
# DATA Q2M85SIZMuEwVNjlSOE6CSP6aZrx0qJN4ZhY/FdJMjKbOu50kPcfpLgZOh16f4IN9TFCIgZeImDC6YHtZPVoL6VyU1o1KJ6MackQ
# DATA lnpHYaMjHPBpoogEoM8TpDb9CU8Bmra3C0BsCshNaC67Ve3K5DUwizjFC2hMg6JHlxdnIXdhxNpwKcPgHmiN12UCE6F7CazQuK/8
# DATA SrsxDrEefYzEh20PcEnGeC4mQFsEXaEf9N+ib4xSwu2/9TVnscNmoRvOgmzyV8bsvw2v/x5YfZdpAn7/ztVx+hrYlx9h+ppjwtIa
# DATA vLnGSlfA8aSDQe04gbtwPx03szNo+vQa2706i8eADc2VLdRwnIxR9NM8j8flWm0Uj5JxZauTDqAKvwK+rLKF9KvZuDt6vdyob25E
# DATA /AXbqmyhlTmQ/IvaxTgeNY8BA1/VYG7d6/iKm+kPYYP0J1sY2782RdNR4PWSWtrrwYSa9dXV5Ow6bp5iO1dUpou5QGiT1AD5O6+G
# DATA sHebq6PX14wk1f5wNJ1U2X6rijXwrLmiIUpfqmSd/73q9jM4hi/hM3XdGySvt+C0OBnWyOSv2UkwTfTWD2B39nuXNdlf6jXcT4Fp
# DATA wXO1ub4+er01YuagCZAAmhk16g38d4tXoNkYvY4yuNJ0Iwt+OUAj8RhOXEjDfNVrWc1x3O1PM/nMD1UYAa9H7YLHtLmxsgVXqQza
# DATA GaWU73rLA2MTLzACk7reYgo65s2VNUwgU8OMLaZy6CBNHRKHirbcWdJtodL56Co3UZq+3QCjmDTRhJXBU6V7lY7iDtwGm/WNDTUb
# DATA uQMCcvSAQchqwA/28QSSqu5LQgrvHaOI91IhjF92egbb4tJ9ewVbGzGmueYtKpUC3OfPCpdhaa55HECvy4d0RaJjHHblUcV6iUuZ
# DATA HlVyOEw36WZjZeW/c5BuE5CuALuw+8ri+9igLmJu/a6FuArZ1tQkvPFXrZc8fhnuKmzNLRkq/WYkruWJCGy7WnY6hofmyrXTHPDq
# DATA R1dqcCvXGiAWFBr3VqBtQLb+j5ImcU5wTF3T/Ujv75Nxv7t1AmSovkYzc7bJygqXrtOUdJ0iYkDN3MVW/P1vt7oOrfYw6wKs/9XM
# DATA NVKza9RXN1SrDEAYV3ICp/iV3fDdlRVdZSWqr0OV69NG9XS1erpWHQkJr03SEVQ/bTD14+7wfoVsMjdUxUzLeN6djcqr9XXsurpZ
# DATA 3zi/qG7U8aECFH1lXUYqMKlsDYATApRAsSsOgL8CSaDMGtVafWVtA6puncWvZQ6Nzc7plgzqOIX9eQYTXaNBry42uAaT0+oaDG2V
# DATA AI9Da9ybMzQYy+oGgtPtm3pe456hk0igDi2u+Q26NWlnXCOA1dQ273ZOr/tnJ9Xs/ERjDWVC27L2qyBIPJ2k13wnrpKdAZ/oslUw
# DATA XVxjdQUQuYoXpjLWjGrRJtJ0PRA+pOyW5uKqf3CRuBzO/slFkgwJkxv1DQ+VGysbmqxosIUw97pO0guG5V2G5TrDcjUPSwW11RVA
# DATA iOA5BHcJd0JEF4h7wL94463K0Ur/XpM4ZC4U/H1a1HsU88klUv0WssBHPuvR1JzKlrctr+soDbrC4AlUsNd/nXS3flQjGQzMews3
# DATA Za2Bq7yFGTcA0gjoAhKtyQLOk1rmI+gKW8Ga13VgaVJFHGucM3AT186levCXtllD2js9G2bNRm8cwX9F9I02KLUf1YFzgG5orkRi
# DATA FVtjlnR9AzYCl+71T6bjRDOS5m0nJmmo1U793urY7E+cVf0edStXifm4cM+r3+A9WheG3wPNxopBayodxmmpTATJHcLCm8kGKpDv
# DATA HPnbsEdJHUVADN1SADpcuasF1nKcjOBWWF6rAp7DopRXqrCyQDbMiK7rnXjcvbJOFuvU2aSj3sfCbDruoQv3HP5iNjvK/UajJt7+
# DATA a53T/qCbnyYVqaP4vFo/m8Kl9MpmEOgNNITfbeT5iGF4gWb5NjfwUXBPhdnnDSCy6/DfGvy3iayVt06En84CkMzO3S4FjLo+YLAR
# DATA jxrynJvDySnDpLw6rERqLkUrsZrn2q7rWm7q4zqQAZgWEgldJBJugAGoD348WvHUxx/YIsoqrUPu7j3c2/Q2sg+/uyv4HubTnyyC
# DATA owBMoTiKvDi7hJLaXNdRtqC5vdUvEy+xJ1Lm5FlEdbbUmX27wQ5cDe5AaouNAa8cYsXsnk3nI8G5GTggM6PzYz10o7T2whqTo4tT
# DATA cpZEatWESxlRUTWiJkxlcqnnSCdhnc3WHR67vqG4Ztl+q0xWlCwywGmv27Nb2cJSNVLgSC9GjjnoXy3Abnh3FKAccG/qd5IrGyT+
# DATA fUxtR7U9+Nyt86LA9fLEYqL00FcWOCa4bhTjdQPugwsgiYMbkX5axSfk6fIbwj5TXHodrSzGoLmjjEbWwSyfMjjchydXntwANkh8
# DATA 4ktHmLWdgZt6gVb5Ejl2cebeZv5SWbA1j2OPt1U7KXe2enyBT8KZIZAmI74UYpVmw7pnNdaJUvJWMID2hTfdODtNXAAfnva73WR4
# DATA 5GygW5weMB5OrmG7XWk52Gti3e27Ed4PTH/rc7a+Dcp7RRvbE7vFw8sLFENfo26EV7kXn/UHl82HwGKlcC5XX5Ye94+V7fuTdJi+
# DATA LFXP4B9q193zAMsunMP9QWaBaXVxfBRZypUnlfKFVh6/rvqMnNstbWG5RM3brlvu6UgjXpWLj2lxzT7uQ0znAgygj/L3zCit3Wfh
# DATA wAaer1LAEWvQTWUx+SRQbCOt9m6iBehQH/UHg9o4vZjPZQtPPUlGetUVGV03n5CI6/2/LgR6giI8as/fBdf0SS0ckMhBPMqAK5Ef
# DATA 9gXaxkA6mCen1UmXr2UEiyaOxjlHF0LGySxe67oOI0iuiJIzAW82lmsNOhstGZHFNDDPkE4no+mEPBJ8YPGdiqz0a6i2CXCz6J4W
# DATA T9LxlTp2Q7wsY7QidBqhr//kLOn247LFom0CWatcFQodbEnD2ibSXpEquLtFeJL86UTIwl4UeN1lMNk4Q/fTwvuntynX8OZqg9K9
# DATA T2qhywbRarob3YgZU8xq8XjszsNXyDVUNrg3xAXBkmMYiq/lqz0lY9ywuBRV8YF9l7LRc9VjnxUbm8eL9TXCC4JhVXG5heMhsQyL
# DATA XuhU/8gsjnOhWGUxnVw13eNh8dkvPF0iIoH7DxFyQCU97xGpNLPaOOlOO0m3dpbSsvAj7I6QTowav1O902SjD/gR93DfxMP+mREZ
# DATA mXN+i5Qi/cAXNQz2zlF7kbdhVSmjfIEH88e0msJ+WCJf1tRZVIG4ALkbHsP99JW+bfiFrq8djaGy2kILQfgnen02GJLuE+3ymsvL
# DATA FxcX9Yu1ejo+WV5dWVlZFgMvNCD6OH2NBVeilWhzHf5Pal/E+IgNAOGZXkZMyMzzmOo1VvF3D44gsplaW1nrrn+Eho8P7lO4ErIW
# DATA etLYjBofna6tnt/7ZHX9vLFyCn/f+6Sx+SOncm+1t9Zb48o4RFcrmsEJmbz7JO/BRR4u8zSDdCD2bVTQGGMB4h5f4heymzPWdWL8
# DATA pN/aSuemsejRNgBJl3Thl9oAzwLJRyvR+vpGtPbRerS6sTJYW1mNGvfWamsrd6PG+poLmO5m9zhZyUP17lq0dm/tu427m4PV1Ubt
# DATA o41otQHVV+6dw7+PsemNlVW3qaTXaxCM6brwiub/wfrGxspGYl7W9NKv5TrFVu81ztdXG2crtdXGOnZZ++gjGowMJGowVrxlD6ur
# DATA K9HqeuO8sbo2aDQa0ca9765+dO9HT9bXPorWGoA+q/cGjZW7tfW7313dvOdO717noySOc03e3QCofHTaWF05q22uwP/P8ec6vF5b
# DATA v3faaMDrjQ34/zn89EZ+vHm8st4LjXy9EFPFfBEQtYmehVciCW4Khm/R/b4pm2VLXW2bH2xubB6v4QstfYIq9GdLMzT5N6vND5JG
# DATA spHc3RIZW/ODjY82797d2GIOo/nBca9zr4M1SOwMn7uba6vdLVbvN1+W9pOTNIle7MJ14SA+Bd6zuk3mYxmQwlqWjPtYV5G0hYoj
# DATA eaqjtSWwTIakN5mbjFZdofM9ZgR0cX0ayf3m2wns6X5c5aY91dyWLwhD5qx6t75+flG9y4Iwalgs5Ra53s+Ub8FN1W3RF5TbbJ4s
# DATA TL6CkqG754RTauRwlcxyUgE8fzp9tCS6uoF6wOgCWALosUUstFq5GXMToYjWN8RwpQIrhcysM9tqbmrzmDuR7OVwjNiGL5NTuc7v
# DATA 9R/gVn9ZQus9IBL9zoQsyYdkABn9McYXi1oPtAlk/YfTZHy5T3YB6bicVayyuvD2eBxf1nvj9Kwcrrc9GEBVq67Y8n0nucTQi6oO
# DATA 7vA6mgPCaOluGX0YvSw17QGeJWfonc1px57EozI1qnOFUzjjV8llNerFgwEidyW6Qod/+Jsb4DD5ZFO2z4PAjNS7AOqyNagPMUZZ
# DATA ZUtnFabsKtDpdDCIvhmVeRT10zjDzirwSt5AU/ymaQ2gGaHrJ8cioGD7W9E1uip3TmFU0sNNWsTq1/asyamepy2pYq9U9Yyrqw9b
# DATA Agtn/lnB/Ks8bsSS4Um/d6nSVmmwoIlNYC49dO7ODzK+LOPluaKXIsEAtX9cfln6gCW/L0vQNAYbSgaYorWOpcU7Awri05bX5Gl6
# DATA UdgmM6M3bnM4PSv3uxUzm73p2XEyLlObLzHoH3ytK2g6VbtiRFrmcG7YOMezgJ5elvBxGbZzf7il3FzYx6VkRj8d4/BfPH9cZ4vL
# DATA p+QeAs8YvS36GGPoHWI7R9XoChu+xsXgqrG9kbj2ziCheBkvSzGBIa6j9R/GrBkP8EmNF3cTjBhfdQb9zivYU2h6etA/S9LppFyu
# DATA 4B7HQY2Tc2AqzKCgHcz7DvyrgIKHgvoNtQp4m8DObTilQzRoLveGOHFcG6xAgfDOMNDHzjkM+rHEWoE2sunxWR8Wshol57RsD6Aa
# DATA /axj1Bj49xEbZpVlqakhuI7DVei7mL2jP7ksV6D9IRa4lqH+MQ7vkB0u4vPkCAZZh4o7cee0LMaf1NEAmOYs5mB0RF1gQPiI4zk8
# DATA kh5vMQXsZ/RvmQpAj6re4ZFaJYA/WsdjXM4Kt8/vLymSJZWvw6kymHaTTIZhCCJ8hf60kdxkW4W2xxW2TN9waPu0acuXGK1T13GR
# DATA H/v8JiDmPk8HCAz/Rn+j6y011LKpHlgbwhfsT03nfYBK/V4AHDABLgVMNVxty+c4Cswd3IqCxZvRYb1Ov7vVUAm9UMABZzhNGgeR
# DATA V2syPGgHREjdTB0NVm2HPh11lTG5Y8AvcP9YzN7DNu5bXIfbIpP2TMzZ0ScUGIrzpE47/Jr/c9FbK7xcHE9fGwSnIplaNvikgaIr
# DATA Fy8hV4Y11K3gImIjOR7gZSlkyWcPi77zwOgnD4CWgZs3+MDfFSXmpxCKkueNjaPCgpgYuRb/MmvYTRnLSwzheQa8B2ObHkIR5hTA
# DATA Uw1AsEc9An83PIHLILI+EbHxke4XXnpYpnZLAV5taYeKMGYh2hi8EdxR8EF2VZ/Q9CSUnAvAqQ93K2LGqIh69sk9b81djmWqwU9A
# DATA pvjE1PI3GYrRj38Mo0aEAPp1VoZ/0sfpRTJ+CMAraxDDRsgo+Jrq0qkNXBJOnPAaPSag3MpWZG0IBKqLdPDCRg0KuojBe+C9TTTd
# DATA 0RhMpLlUom98IyqrobVaaiQ4KGpIo4CGW6slU0H8xSKs1oOeb9EQeLvRzwrP5cMPeaGE2UHNoQI/PRh2B58qXMI0y/BA6rhiTiSJ
# DATA VMRriAV0I/ytImW844PbIiylESYZHRyw8mpFA5uR9hHuRQspcDp6HWduYKcSdIRjFDQFIKtGKi7GYUHhOMqV1gPiGV+WvqWdwnCb
# DATA fFhGtu9libcezP8OP9MdkLb7JP0WmtWVVysf4oT/y2f1l/Bn+EjdktN0QqLWKJ5EDbixfMgNkLMZNACVwv0A87TsFjV9Naiv//d/
# DATA tiqqAS1Qr3PGm5tvgMYh82vH7K8ds+c5Zn/tkP0v2iE7csyNxQ/6n7Wjtpac0WfHA3BguW/vjyhaHp5s/S4mG1He26Y4mRWTn9w/
# DATA L3/u/1a8GucFbrEFpTR+ljg/uA+U1t+GSkmGw9Cainus77I0ePwiHtCT66juK694S3dSBC73dDnsqGGIHPvB05zui9hU4Ac8x3+r
# DATA Dj3QPAgAowe0tE1Yd4wHA+uF/NB4colGxbr+iOMGZKcxecQqjIrE4AKuheSOPD2Gcy1CqW6EdxBo84c0DrJS6qfjevR0lAzJz7dH
# DATA vvtQSZz5CVkjaOsUsQ5wMmIzBErDhKWhZ8yxAA0NJW7AgpF3Ik/GreIIkD8xDRu4BWCyT9AvTYfh+Q66OSPCoXc3ZXSInk21uDca
# DATA 4muKfsR99OHTdIRsQ1aPkJeijxmxVGkPhTywY7rIqcm2AXY5pRAAvekYuIhpPhrCv0xnW93C19zb19zbPO7NxbCv4+t8HV/npmxb
# DATA IYP4ZcXd2UcTNiscBHaDsk0MnKcj8PzhYrzNOi7Rui+yw9U5nBzpP4j/QKWImOSod7TYSISYjyWZgAKySAHLZ5X7LBNVG3BI+ihc
# DATA JG5N19PkyrwhqRiZf9Q3yIhIxbCG6ZNBFL48i8neaEOMSZIRWR/VmbIv0xi9obIUQqMDPi0wUFVLj1O/0MNcq2++x2GyZAQ+KykN
# DATA vbjPglYZlCqjB6Ur3U+J4JvBrWLPDxrN1ZX7y6lwhX6ZDSmzMaNMY0UKwQ9T6v9j722b3DiufM+vUhs3PCLN7haeH0xRCoqSbM1I
# DATA si5JWzExmhcFVKFRJoCCqoButnUVIcnj8Z3wxPrG7MY6YmLvnbgRu+/2hSybMxzJoiPufAH0V/An2fM/JzMrq/DQQBPoBzJlkwQK
# DATA VVn5nCdPZv5/r0q0sqQoW13nploFowezZjCxJY/IbOAn2JBIhvRe3hOs0qlWQzF66aqZXZKeJzriF41pnJ5IDrwqQWD+pHJL1mnt
# DATA ULJLeoeaufK6ZXD6mJBZHYAtTcVGozT7KaUKwi/GoHyfBkPqn8Vo1F5rq/1jjA1H3PLZUDQDbZSIHXng3Q0Cj8/EKrMg1cNnZkN6
# DATA 72ENRal6YiJgRtopZNPF0ctGqRji1OPgjdiFQW8bTwcD/nGKZVga1KNEG/8/SUNR3hERG9H9iToRZbFIzGsRKV3nsWCbchTILIFh
# DATA waY0eiLMa6IU00JK0kg6P61yxfb6AML3Vi+HMbATsl4mZxp38FIkXBovvtVsD4DOcHaG81mGc8FAcpazs5xXm8NXQLHyIb2NG0cq
# DATA mnl+oFpDZjYXNBsxuBidN1ZEfBROqEBHhyJtl5deFCZY3MO4FSsJyEwpUfQQi0ZywT+L7YpSCmrL4mv9KuvPaSFn3dgpxlVxmRmR
# DATA Slgw2KcEvUVfosti2HGvh+1fkOnjviD1+vEx/exRCclwyXl94CnjApKWFLsjjLvoZ+Iedwyc55Z8pfisODn5QW/iszfzboLhamBG
# DATA OpMiO2nvsVPO75KNAyHNY+qxspRh5N3nKYNsiGbUqT9IebsYLB0k8ZBssVT3agEVXp96My4lTqac8qEQRiwqDjcimU6HMncSI0b7
# DATA y+IhWY0TpS7owyp45GmlkBXpfMs/4Z54dUJRhuKqRBnrND5Q/sdeGFKygqjH0n40u4OhBoFD7GHEPgSqVhPZgsF0Y/oFTRG/sAno
# DATA PWQMj8d8QQTIlhUzZeEYpKqoE2Isus70RCr1yQT1GZtEVyTyfpguSKCYFbkqPC+oaqo6WanstzyGKjwq2QBNkEedJFxkxKJI97Qd
# DATA CcKbH0Q4eycDndipSkySau996L8ElIlkF7Lth+TDzpuSMcFPPBKPq3YpM6QMtXso7xR7Uk+ltdRpL0qGvDiyaG7LiXpIeSPzcTB6
# DATA xzhGSmaSUVunFmSs52zxOxX/tdxP+cHVkUwBNT33U7GFuXfy3tfintS7MuyBTWkF4jY+ZGo8j9g8xtSADF8qaX86idBt+AnrdA2V
# DATA 8iSrn0qHAi6UuI3JQsB1NaVYmtq/GsXHUj/RSqiJoI+EYKtO8Fsxhz/BvkrktrRFStAYrgTuGnlsE7vE8iug8VMpY0tDNDBwrYSn
# DATA CwkVN2Uf2UiUYZJCKnIckMaODH9OQTbXDfMUYXRSVJM18wlbVtay88VmfgGt/c8+2zMMnckh4LzJiU3Q+X9PfzH7w+zZ7F9nTxQj
# DATA 58nsO/rfV6e/8Wa/B9OGfvic/vxmHp3zP+iHp3TTU9zP8JvvTn89e+LRl98ZiM43FKhc5q8A7Xx5+us97/Tv6Dl6BreBnvOM3vQt
# DATA Y3z+nn4Qps63s6env9KR+RPd8gcB9QC241g612A2g04Zx5eow+nQP5OcaPZhGFM4SdTVJtiB9/bj8UDG5wH3iKH0DWk/GlNvMbC8
# DATA EbpzxCriOMx8BtlcKB4M1PhEL9UyvyuhOlhOVOGpluLQOvn5je5BLhqss6hkdofXyaqOuRUmXXa5+MBA9KbN3e/Jdx7Rt0zY4XFN
# DATA Deux2tyKwdQBdtYstu0jdrD2HrL1icLZy1yMbPwi9+CQScMwZ5j2aTzhfGS5/XSCmWpht7JGaiIIcyglmszxdc6ufssdmgta1mVh
# DATA ds5OhuPsOEtgF5aABu6c0wB4SZybFzb472TsX2vo33Tkv5iBX6rnfD5kDJ6r17p2AeOxcoBRPPlXL0jvPMiDXjccq5VEVXiUZwle
# DATA qsA3oWRNqvJmz1MS2F7SP5n0hxyKHDDhDFoXwaOKLFuIpI54wHiZKVZqoZI+QW5PlH9Wjsn1/KMYo4JizegY4wUCN+HhlB7UFoM6
# DATA V3c7sxeEWATfD8yIY380sd1i3XjsGDuOseMYO7tk7Kw7qqw1zVnXSr5gk/88Fv82DH5H23G0HUfbcbQdR9txtB1H23G0HUfbcbQd
# DATA R9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbSdq0TbqdT989J2mr16r3uNaDvza89rMXc4d1XuYVem
# DATA x+9qNHIKafVaIddrjVaemxOGrZ4CG+FwI0Wvy4FWGywD0uVQKxIMS2WUa408xKdKGb4AjdSsebVKyQPdplxvD8qtkldpFKg9jXK9
# DATA 3urMk3JqVa9Wbv+03K71a62jSqU+LDfLXumn5VK1X2seVcv5KHQrQa3TWZCIequUJaJcaZtEVPMBVNqVoD5P7KGM9WrNSl/lokXP
# DATA MQ/M0XMa56DncI216DlU+XP0nHqt5Z+HnlMPwl45o+c0Ko1yMzD0nG6r0wvaGT2n0aiXW7un56g6vs/V2IwLVSHo6OE2d9MiR1WV
# DATA x5G99tHxXostqdwaU73bv702aaf4NuXgtl1bYmKou3C0YDu4HTvEedyOmmi2jLGKMr7NOzn6fhAf/6DkwbtR8nRJ5gA93K7nX6Hd
# DATA 7sY0b8r6SS7XCzfl1spkOC/AcG4v2Q8wP1opStIiT62s264IWXU1amjTDSWrGTUTv7NdqarPWE7xyZX2GTZiLvPswlSJ0ZMXWCGO
# DATA suMoO46y4yg7jrLjKDuOsuMoO46y4yg7jrLjKDsvF2Un6on9hnUP1PhP7W9Sd+6oEVMNXPLbHtfFm7c/szA9n0q+ITPucDA4dWSC
# DATA uUVPAL/z8Su35t+hKvVtPaCol8zfmN2iDmjQXWzn3laQoA9wjEtaPpvygxM+naPfWozSgffX6gy8dSiND56hrKlCmSjs6xvohzdW
# DATA jfhbygpjM5uk8uLUweTxJEsz9Y4fv/KedfLOJIO6S5UCmegWzvm4I+juCPraR9DzB8LcWXR3Fn3+1OBSvc2rcEa9UMdzrcUWp2HP
# DATA HwvQojKnmVqKEr6NgtBPc+gWPhENZUuQi3ikSak7k3PCWkmFt9IVTsuuewadk8D6jBjLWZxPSYLSq+BCHYseX4dlFxG/BYdB1S6r
# DATA ef16ZbuiCvInpQavhMP1j5meubnC220h/xlyOCZ6UWpl9XKVd2MQszS6fM5rvFt3mO7TfmpOoR0WJQ53okOT+1jcdZmgu+pSOawf
# DATA qs/L75bj9axyx5+W38l9rpKZ7YbL75N+m9PPn1aIystBUy3nLnaoreaOIWaFlnuuJsB/bsu6Zr/AW89dnZ4HyCed58U8K4htslvf
# DATA 9AJiVXPNS6acG3/+7X8z6ShG3Mr/MUuUos8Z+ONMf1UtJfKetGQKiQTYaDFLMYygBM9a1FArjagWMpTJH4+pTrK+LnXMaH00iR1N
# DATA 5Pg/9Fgn0D/SOrSsVc2LH1pk9pgqtzosrnxedsvMTj7rppEdrDaOM1xWSTE5o49e0gX2BXNNoXstEEBRtXWjIsoq6qYF9Mv/ubyA
# DATA dKWX4nkXxUAVOdUF9PA4pjaaUMfm6VN+qTJBqE+ajuCJpCFpfOC9S6M8jJxhfCSCFJQGFhyAsMFhyN0qCkj2D6tyCrW6hSqt5y8V
# DATA k4ILKxfTLWxaLP/4P5YXi+pipFREDrQbJzQZMS1npCbCcpmnOR3WdGVdZfnkjX00rEBMB1Hw7VEfHh+rIsrbkSzNzmZxbhy0LkcT
# DATA GNHPX0p2ii6soLJ+eeMe7jfLS0r38VJUH/nJ0OPdXVkXd4xrAscJjqCFTSVzSAXD6xfo60IZ7keBSGmErB4LnelwBAiOlICaDXRC
# DATA JndEE9HkwO5Y+2emTjx/+WTJuLDSeZ4R6P/6/foj0D0MsmEiQ4KlAz5ku5rilTxSljY3KX/A6uW+N5zS+DPwE+yTG0M+GRnt/VSM
# DATA RzXAkIkEhoE0G5T485dELrrXoan807pN5UHcm3gdVHsfpZN1axjjO5RFQ2jZQDOmSyMPJgesCO0HP/OxP0fV+BSFlbA9Hg2jAc4b
# DATA IKegUkGW+ifTSNRqoILIwipSgFoRegtNJZeMcxVQ3ggUj6ZtBJorkt2vfxBr36PWFOLZh/IJxolQGTFAx9yJ64JVwj/Pww56OcRd
# DATA HJzbudLO4UpznrOXxHO2Ka/7Sqg75vZfrsZ2y5ybBtIJtmqSRXnITq2l5O4rqgJ5jUTTztKGtvc97oLiPd9Kts7yXigjuozoPZ9y
# DATA dZtRxxbnCyZBB17ZSGKzM2lPfEeiBnkcG8dF5mRS1D7lEB4Cym1k/rKC3vOmqeBLIQtIwWBnhCQhLWphL6g1Sp+b62Smp3kuLfAP
# DATA 4OkaHQIaKIBx0e0xUuCWsqAG3yjNrB8YOVGY1ZmoqK0k6rHPhCzWiZQW5j2wvj1sxIXe5lGuPshmNsks3q4KTdRR1uBFu1DnFnL4
# DATA 4GUyHu0gnPnozMe1zUe7rrl1WLcO+5xW41IjdTfrsO8L99NWis6Ih5dDqrgISjjv/UH14mODuWVO9VOG11a3zq0XZgtJ2fLYsrVF
# DATA e3nDXq1Zdn/B0V5YSlj2VM79m/NpL3ui6KYsulmXPVf0nhW9gktXTnOlwJusEFNUpyAKuD7IQtMbr2n5SlUs6l7wy2XPqbDE1TlT
# DATA TTovLoLjkLnm79kWlae599Sp2zaVuMz0q9egiPOmguFJrgFdX4Q4FpomTEIdo6dPlaUaD+y3hGM9nsiMk03wUM+kDESS2o9ZrZqy
# DATA qUCh0TN47i3dkaBvsYdnTwmE8ATAmOzqqY9giUvfI+uOgbiWeV85xQTC3VigUU+8Gs8XXDZvXOw0zupatrcQHE/dR1FJF0r4bAb4
# DATA i2MlW3BAlkKKhzk24H9TEL9ns+/ozx9nT4Hhe+rhG2P5noH1993sCaB883TA/zn7ExP/vlZ3P5194zEo8Hezb0//99kfZl+dfknP
# DATA fqsC/UYhBL85/QWu0W/PTj/36AuIhAICBJkQcZDnACxkbuCfHAzwOlj9ub67Fx6T7cCT6LEP6VoFAUCvPuxBPqIDyS6NAaGOD6uy
# DATA dxVWN+4w80B1zx3daek+ezrm16AJcXhkZHTFfxJOpuOVCMC7kLrwgmmKzS7Unh0AMGfv617iovl/88WyO/ofW1hMWMluzdW3Is/8
# DATA 1fAkHEchWRv6/rfVBQ8qQ0Box8mWMYCsHsZI6OmEx391RouamCMBrluE20cBUl+DRXBq86Ooh06HYfAMccZ2uSR+DA2dkM8uiykP
# DATA gxW1kDq37gRbGKYs/S8/pmrzid57oiuauFTJEmfGDaZx0eFoDgu4frVcbuvMNbzLggOunxgHCXQWwvYsBI0GPJdh8HI4AS/MKNiB
# DATA TbCWSbCxRXCxBoFU0WJ2GDPgyrSqXSABrVSr5a8lUdRwMXZfPDrxDhM/mPoK+pdmqw+QMcyvsTFqML8ocSKbPrE0f8SuJ6y1sSxi
# DATA Og67GPmNKbYWHNCM66zMTQlOZR8dZWAP+DKugPtxbx+Vk/tZqkMHHlRscXzWF8sBPjom4Kk4KLYakj9O6FLKa6mqtJX5JouEHFm+
# DATA 0WTfgfdBCICcXJBNew+mMEOSeHrY96YjKqaJnGHnF6cOI+gwgg4juEOM4NrD0FqTpE0N6gudI5xnirDNGYKjCjqqoKMKOqqgowo6
# DATA qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqqgowo6qqCjCjqqoKMKOqrglaEKhs0w6JXPSRUstyphzb9G
# DATA VMHiCvRaTME8PK9ds+B5zZKB5zXz+Rp0w1rQW0Dfa1Rs+l4to+812kvzNiuYYbnU8irlplcu17xW02vX98v1ileulam86Gql6bVa
# DATA BSxfs9FudVqLsHy5KPM+zPn40gst5GG5aeJbzwMmS2Gj21zwfKVSyZ6vljJkYmu956vySpVf9UqWX+s9X6tb8a9a+b3m++stC/lY
# DATA qzY3fX+5YZd3OYt/dc342/VFypYfr633eKNpJ9+GPa6Z/fKISn6jven787lXWuP1m0AipZFoSKT0ZRYkstv0g2Y5D4k0jxhIZKVU
# DATA 7dTbOUhkpVNrNuoZJLJbCkpBz0Aia91Gq1XLIJG9ctBo9XYOiRyhP99PH51k6xxyhPIo3MK6Q8VydWibi+0H81ptEeZMH3kZzWYw
# DATA rV+wh0VluB3MAbSL8va9FYp9p7Zy1iNW5iKqFz0UF1FKUN+jsuTTdXPtoGFRDT07W9Rtnt7Vks8bPWvFPvmco7UAdFyxQ0HtR5B0
# DATA 7Kf0wzD8AUQvl1MaTT7sFZK7wvQrFvLeyvJiZ4opMrEH56qJmE+VdXKKQ3AUSEeBdBRIR4F0FEhHgXQUSEeBdBRIR4F0FEhHgXzJ
# DATA KJDzEMehf3gHph716jhjRkl+Vb7qkyzIBIVcfN9WFECrukVPU114Bxsib5Rv3vr4lf/47QETD+8u1BngZ25I+P5YDhvgjRTMTRNO
# DATA BeH8r68knHto8Xx8aeiPpj2fdfrlVJecR6TmPJajbzhU5QtyIXxMN/LhTzIHUhracoTE3Bkdd/renb4/4/T9giNc7iy+O4v/PGfx
# DATA l+px7vSMvigixnwQOTvuLcPKG0af8/LlYy5Cq1NGO8iomij0+ICssjpvDIc3FSVRt9ARO0AyQT8dhOnWzAWjaNms55Ukh9FI1r1K
# DATA SnWSV4GU3iT22/Cvy3mKZlC2q8qm8bYCMVG3r5nYV+qLIl+xot7KRbx0UF8edTPe21HXF1U9uhGEh0lIU/UzUmCFZVJgXzMpaCzM
# DATA /qqd++XKisxfqtCpWwlqtHQQ11Wd0xpxmYdIdybSmvUR95zZh3nTZHGToVdFOLLeOckauX0Di+yLfL4Ud5hOpCuRJwXPaKpEFgbf
# DATA 3DkRlGOuX9K6A6xfoUOjfoSMQGUgYr43FrMhiDD348egIcySGsf+iQw8Upw89qdaWONw6tOIMwlDlgZXwhafUAdH5heO1itRkAUx
# DATA WkPA88U7sF4YFZ1l7SzrMyzrgtHkrGpnVees6uVspaukfJVvBb7JLyN+9RPw94zaEVaxM60j1pOBS3zP6DcJujgcRumYJWi8h4au
# DATA wsY76+aE8Mwdh0xm3fP0ng2MSuEYy/gJPYL6U7So8wTHObErcx8N/e9ESvqoHyfRz2MjeaMU/H0v9Xvg64QJGUUswWRKJR3HmUI6
# DATA SxSxaJSaRYR+esIjbz8ehhDl4dkE2X17wskQKR7cS6M1DawRTAjurFLKLawiKDVwbFVYMmXI2TZBqOP+HoR58h0gtk4o1R7wILMO
# DATA 0dhE05HPhg3VqwPvzWgUow7RMxqzqw2BUfh4woYkL6kgg1Q/GqdwW6keVplAUgWG/DILFLrImFiYtr+ywQiD+FCn8D5ONEu5SbXK
# DATA zdkiLMhC/SPKxIoMd0EkvAYnSi2fe/z0kdS0bNzQmyJF/jVl/dcepNo5EVqRlKGnjAvz+CwYcNvI3km6KlEfipyXtIrwRElmYaQe
# DATA D7kLkzSKKpjIz3ay8mAHYGac+hMjGJaNR5QXVGEpjTLhVHpKlGXY5TrA/hKuyjhCk9gV+iSFb5xj85gCmJBxGAWgwR54b8XcJDH8
# DATA GWUyiMApg7GHzi+xYjNHQGLL6kzdVxOXjq8Ke2op6Jv1FMMkNVdkkDiRC1pkX03O8s/zj/mpl16cyk2rSjwFUv1Z1pcxsUBqbga1
# DATA VzL7z/W+siFPDPwThQ7Pmyop9YTbfWeFh1DG9QTRUPqf7b4B2xRf/0CPHUjTOBx1o8F238J7uN/WLUgvodk96HbfVxeARS80e4ao
# DATA 4bEtOaLWln/Xq9PBzhi0L978ypFo3dRqfclgN5F64SdSm6Jnr5aEsNnTuwuGaTGzt04wXaB0fDa/dJAjKIgGMLsh87rCK/C6V0tH
# DATA +TpKiK6JW/ByG8u1EZ7JrUq+mMnGwdzkOJv27nmHUGjO5jSYhXk+JsDYamXmoV2aAtv6saLaiklTOinMSjNvQsGToO1vEdDN1Vqy
# DATA Xo7Cs4WkUSeH/liDHNYqgwUl+mESskc9p4adhmmqWYUvkemWEa46/qMwyeGt/mX2BNSp089n3ykG1R8Yc/XV6X9lXNW/e6e/BGZq
# DATA 9rt5uNU/g1bFQCpwrD4//Udv9vXpr2d/mj05/RUF+nTPm/0b3fJH+v4lvnuzZyY0ULOWA6++BNeK/nZMq+tAsqU6jOfhbKAKxhLY
# DATA PuOeZYggayvikSCAawJy5apzwpxMXBojdlpwv9RTYJ5ALsXo42R/rTDyqOdI2dO1EmH1JjbQop2E6CwcwMo2QKUTuGh6VbFEdseu
# DATA giR0UHjvQmQVVzFz41tc4XYDq6JRb6w2/aKWYpNwHPgnvI+Q6sej0AGrziq3rXOq3kQz4BIYhwnOirJiPY7j9RiwLacvPbLdoWWi
# DATA VkGsLXh6vR9i+YdJGEQhvNFgFFCfGibwdmXLKapfjEZkDk0lh73hNJX+TMywE6F6d6NxOEexWqemLrdnCk3vsuhV6yTCcaucFXBu
# DATA K0Bjqs4x+L8UnqcLGvi3Pu6vNeyvO+pf1KAvlTGfejPIX1Zj2QV9Kp9Erx8OxrBOyPAAgtlELktw0j+Z9IdYkZWk/0CGWgi944TL
# DATA hD8ALY1skdVR6jBBM3qXDHz/iMbJVGdHItJmvPUAa7LJlLUUKf7DyHCBVrOn1O4IeJhCLFGHfKZLBmKO/ZLBXFwclkHAeCIeC1Ix
# DATA IfbR/oOcecH7APUmCoUC4pewgAJQU/R/7KmAnafXyKeTGPJQXSZ1OcCUA0w5wNTuAFNnjSNrzWXWN3Uv0Go/j9G+HZvdkaQcScqR
# DATA pBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJypGkHEnKkaQcScqRpBxJ6sqQpBrVWqPSPCdJ
# DATA qtfr1YPuNSJJ5Vee1+JI2ZlSaXjVZuuT/dp+udXyyvXafqVUoX/LXpn+X2t79DWfQ92w1anW53lQ7aZXAfWp6pVLreF+uUL/r6mv
# DATA BRAUZXKp21kEgiq3JWBKf0QDt0YfVS30UrXesIpecZAESpQHV4U1P6yHcxGtNctepUXJrnvlamVYbe2Xa3X1bS6eYafTWxjP6nz9
# DATA KtW9Wr3eb5TK75drFa/WKvfrWi/OYmDVa5VwUZDzNbZRo5hWyz9t14Ylr1Lfp/+XW8MKvYaKpYXP+5UWfZn/ofDSVqtRrXRXvHQT
# DATA 1JG0EI06ksZmoY46pWa5EuRRRz3+z0Yd0Ve/V8qhjnrloNcpZ6ijZoeyyjeoo8Dv1tv1DHXUqtVL5frOUUe8w2SfTQ+bJaQim599
# DATA ljESevI3NXN7MmAzjWRmsArywyNX9uY16EM5J1zDOOFk6W0eUGSFPe+Q5xFWts3RQ+GjdeFE2tKoFAPwNhivVzy2evBeCiGyStD2
# DATA BXpiQi9PT6FwmyjVpirafP4sT44jCTmSkCMJOZKQIwk5kpAjCTmSkCMJOZKQIwk5ktBLTxLqKY4QH72iBO8d3+l9Xy71TwJZPQTs
# DATA h4ybvdT8lPpsUfLVE3P1JKQeWV3W9KF3EC4ThHq3KIcOmQ/0EcVQLh7nQUTq9wcUPP+cLvz53RFEkWAs0Pv4vpOF9z2MJ/5Azvfx
# DATA Xe/7k/4B+w1u9G4d30pvnaibbc5QdpLFHZV2R6XzR6Wtc03uwLQ7ML1cyu8KHKTGmdReVs39E8/H7zl58wkrn0h9RgkYiXDUmz38
# DATA DNm8wSA+Xn3Wdxg95uPH4ySOe/r8MXTGTUOl8RdbUaZJmD6HtjmNiMkJkjKhLEH69HHLu146HaNTDQPVoqPUkI/IslFgo4QGPNRO
# DATA yOkNogkWcWKaPKSshC0gk24yHXZuQxsmGvF57NQcqu7B2XvE53c/ggs3p2CSsKa7KGin3TjmJ7rTMWS25VzzKgXte7AhkhPZR+fx
# DATA EJUlrQeRdagAIkgu1VEYBqnuziS96SQRc5nKsR8PAj7riphTYmkOzHLgKJUefjukKA9OWCjcZJspO1HWYZl0nErXquicBkzkBvEE
# DATA SadLnfh44PmDNOaDwSslwt+h6s1NR45t01vDxCo8FmzusLXJ2aVvjlJ9iv4YdRHdM4v7DHC+F/34gceK6llP3sWGlBDy6NGAT+bi
# DATA bHx64N1jtWauu54G1KA6UOQRKlLrB9gIxGGZY4hK1d+fnCXqzjnHcT6mgcToCmI7Ks6/ezhKg5dR0/GH/Doa6Lh0lCR8dzqRwsW2
# DATA mrE6DSw68ea8N64MIkXhQrX4OWTqGY6TGkXzRxKe+Fc4RDINB3aWROY8t58Mz6dr/qYIUSPrqPFvLGyORrhtZfP7yHwUXg/Oaemd
# DATA diBonrEtRfAIRcGGqJfpEexA09woM7JRM1JtD90sxrwdSJzf5W7f2EpKTeLilMBfnIPcWSBuRuFmFPkZRbFKuWmFm1asPX1YOv3Y
# DATA 3bTiAbIiw+FIdPSU4sprA14EolQcaXSZPV/ejcOzsJj6AdNhmQsZnaN0HiBpaTnWM3Pt0S0/0l+8G987K7L2gybCuYsZxbO1KM61
# DATA uhXl9roEVfY3MqFkMFkjlur2DPGqvudMqrmo2ZlZzRNSV0RNnJ70c84ruUYk9YMmluZCZtceNM+KaGVVRJeCUGX+itHKamnXl4Yq
# DATA TS1K82JHRrP0HepbqHV4h2Yuvuc1Wt/zTL31hmRSp161pu45hn+aZvk0kQ4PE3SU/JRGZmH6LdwsvpG7I/6qdNhkZmogpxGr1UZd
# DATA 09XhjeFjWTPRUwYsg2FSj7AKUmYsz2X1ZVrANhVWmTwtqxCY9GfTEomdOn0QahW0NSinL47t7eg7zvZe7c13hvYLaWhvStm5ZCFU
# DATA 3gGcbZCdN0BtCA2LDvrag230QiUJyyk0lyqfei1kBfnvLTONCkKv2yYazUnlLuQZrSFea+2jziRs8S2EcGXs9/YMQYetrGnaVwZW
# DATA oZ5ip7iUrNot/lq/+vo7SYR1G+xSZC8iXQKjPnoMG4a9/3Kei2mHUd7coQkkZoHhomUXpaopQqaiT6oOMvAWLmXy5A0YmpZaHlVj
# DATA tZjo2vF+gDUrxJzsu0LMRXbXLKpQ7Hj9wrQJ0RjVyzKKQYrjZNieba0WsXwqLz3hLOKKCKPZrxlbPtY2ipn+y/F9gJUgtUCnp89h
# DATA XhzVzy/s8ZLJwKz6URwVfBIrEFgEWx5RetmifH1ptDstchAZbl1weCx20D/Nnsy+nT07/WL2FNCf2R9Of81QH9CDvmCGz+f0G+hC
# DATA v5mHB809PPvu9NfADX0x+9Pp57OvZl/Tj79iBtE3ex59ejL7Zp+eeIqgPb7nGd1D7xC00FKYEIWOt3xFb6AbHVDo6lvUP4F+Ga8T
# DATA c2+iaGEne7IgiEvS0ardqUl4CP6ylnOWhX9VX83gnrBoc44yTb3xSobQvb4vqgaWZLjjCFnWteoSLpoktKhcdkcT4g0B/XhsbvxI
# DATA XVjMFOpFWTf9TjQxnuAt04QEasz2gviKLKLPy84RWqfEtk4TuusJeB0g8P3JtBOakhcPfoQ9tENPdoIfeO/HVANGBoRIhXgEvXdI
# DATA emCNgDU8YJb5arOLj88D2fSRwH04ZB6jOOvY+BJYI0Rii/Cg1VVyuRGzoJ1dFjpodRIcNMiN9JuM9JoTdM4B/uVwnV3U4L6TsX2t
# DATA oX2zkX33A7tUy/kcyDa6Xlxr2QUoKEsZRLQogHQ+zhN43LBZU2/+0/GdmrTzISfGiegCBAEm4t+Zb4IlMKatqC2h/JahP6LUpSbd
# DATA kloTvGCGhmPqwkaTtbBBsK8mOMiPfKCQegn1dtmgH8lyv17YQjAsJscQI0MASkLJKoNEPhGg8p410sfA/MQ9QRfjRVQRvQcTJDti
# DATA j0fU86hVPRIayjF1FNgziDbIGwwS5J12iDp6kKMHOXrQDulB640pa0LNz7Z5L9h4P4/t/rymu2MHOXaQYwc5dpBjBzl2kGMHOXaQ
# DATA Ywc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dpBjBzl2kGMHOXaQYwc5dtCVYQeFpV6pVzknO6jcqnbrpWvEDppfd16L
# DATA H3Roksy7CPOsmaAeBr3SMtbM6691owT2v4B9KpIQBfZpskgDyxuUy4owlLu9UaqdcbvF+aGwPbrHo9/2y236t0R/2vUf0fVBuV2i
# DATA aw2vUq7RtcZ+s71fqVX6tfb7FQCLmq1+szYsV+v7tXq/sSgmtcqyiCuA0auHuQpUq5QRGXrDcL/slY4E0bMiG8Nep91YjEgqzVVP
# DATA inO9Uuo3aqX3kepau35UKw1rpdp+rUSfigiitt/sNBYFXdmcBiR1XtOApPlYNCBKRrdZzdOAys1qq9a2aUCVUq1VD3I0oEqrXm34
# DATA GQ2o0wtqQWBoQPVqs9MKMxpQr9fttbq7pgEpo2Sx40OntWBrqZEIG9f2V1shHt2MYSe7twj+MROlRZMi7UbDXHevdlBj/k+F+T/z
# DATA 61GNfKS0cWN102K7cEIox/1k/xBTY/AsSkF4uGetvdufvUp7/HjvP1VL9Wajw26/m3vLQ2pvGJSOcjoOu5tSibTNC+/hnEllrcgt
# DATA XxxXS+HiE95P6Ydh+IPATx4tZw9lObxnR325zVEwe6UOse3kSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCjiT00pKEFOnnoXWs
# DATA KzvPnT/HVcTwCDdITnlTHmm6EHYEoBmBztMdHjDM5148ZAH0uUPefLwNS0miVuXjoEo8UsfXtCBt/qCYtFGZyOmTFu6MszvjnDtq
# DATA 4446u6PO5zzqvFR8cDdHoN+JWOuCz9KyC7J4elYfhb5qchsXocetBhdUHaqvSjIcqbzRHZ4l0WyeNR1WdsWINLcWanPXbZHmcrmU
# DATA l2mur5C65sEPki6q9+ILr4kta1SU5Z5M4Fo/9FrMnaktId3g5Z771PcpvBDXk9dejZVI4IInGpxdNLZ4r3qTJHzEWpFnPlbnF9lm
# DATA wBAGDcsn5599VVKzhlD127p+osp6qLLXV6X6/dBPpxCNxsHarp9kAtUPJiLJRz1JHE/kBjnWDFkf/xBiz/BHHdOYdeD9hAe3QXhE
# DATA lQYdIDrVoQqbm7GC08SJER5KYjInD7z7vAAgppE8wHqLStiPhpMTFDQVRDTJyVcDppU7ti/nSL1kijPeOHLt44A9NBzNeA79QLLY
# DATA qM5y4ac0O5um41D0D1kx2x9NexiIE8ylJEBwkYKo18OVaYf11COM0xQYY3cW2XpKhICSMFlb4PpFOefr5K2d+WqZr85efSns1U21
# DATA rS9ZsofXtbMF2NXa1ndpNGKjkQ1ItmPTTIqCOQrpCo3rixb7uRZ6F7uQtZ6v11uXtl6o6XReeets0V+bY2JRKNsnBFmU61wmas3m
# DATA zwmZNALU5KUget2B96boBtEsScRqQn8EE+UjiAiJ3EuKwY0xo0Jw5OoGM4qsrkgLP5MNF5PNQ0bdI3qDJoZsVnF+rIVYjKqTcYe/
# DATA XIonuZxxxpAzhgp9qvPmOW9evu9cakVdsqAh84ABLo4HA9HZLwK7VTvx00zC78B7RzjdbCUtkufLafmNk7gbBqBxixRdnHwyDcWX
# DATA 8zx87ruRgTobGu+ERlDNBBxGE0FNy0jqsZYLx2DKjfzQnx7SqHmfhmFNC9zjAMQskeUehXdAh+H3enCKsaskc3macfrdEcb7ifBr
# DATA p4oWEQ47YQARtCDsJDQiCxWZh1AWAcQOpZUoaxn9M3lGwQH7VBXgB2VNQWUapNq6gHIc/DWJOEuV+DTZAMEg7PjJgfce7CdEkyop
# DATA Za6vQGCBjw4GSITOQITX+iyMt0jIkD+mlmqhuGRTUK8/oYKPetB5G4ZY+4u6K2HkfVa15sozmsCDw15kk+SPAOWIez3vkIYsnUTZ
# DATA J+kNppSpXR+KjVyPgVf3j/0TcUzpeKoyTLVbh7OPxwEKRsWc8iUVBW74l1iF+7aSNYQUZsInC1TFNdU5B9aYoP4wb8TrUATCpV5n
# DATA lWoeaWRsgUw488EzoWoITpmWRWZMTImPQCZh+adoQD/vaT8UJyCD7XT9JDlh5ca7lGc+++1UQEKYF3ic5vgc+SzJl2XSB2HEqRI/
# DATA sVK/hEvuMI4Dy90ub42podFo2JO2li/C88G+0ZZPWPWR+pg3NoZ9I27bhn2LXR5JA1f6hdEI4Pgw2AH0+00w75VcqNo6sgPG90cF
# DATA FdKdvInh3u+haUgfQ+OabMtJhZiz3bfxKaCPDCURK0RjP0q8R/AW+/Op2yVR/MWY6lhwmdhPgkP41m28zH9XGJlnDHUBHeaJN3s6
# DATA +/3p56e/nufJ/Avd94fZ7wT5wncx+QVUmGezP9LHr5gl83TPM3yZp7NvZ18BV/MUP+3rp5569PUrHRTdRi/88vQXCi5D8Tj9pceM
# DATA md+BTQMKjYPKXANM40gzu+Z8ceMwBgJajdwTEZi+p+dr4vc45G3bGOQUNIy1e1leOCN3mYGPoqeHwukoWEmZucu3ZG92jJncbM70
# DATA DBdNmZkvl90xZjiB5q4fQkic8nrQK94XQPvZAL2w33eS+CfbRMtQG0jJxk5EwJxmGrDGeCaGgnBwmdVFtXWqjOmEgojMeD6xJ6YO
# DATA ma94CiL30WOP64V3n7cHiNv2EPsjF20qF/YhNNq10jfKbBROWNMcez9oDE/nGDKrat5yO2WuDV0WP2ZV9B09xg3pzzWka5zMuUby
# DATA l8Mne3Gj+A4G8bXG8DWH8F2P4FIXi8nOtk1eYovZBVKmmNCMLGM0J7KYU26GvkLMwP3GcgPwdI2oSFNZrUUyDD9DhlWgJ46ihHEx
# DATA KCyNlaGU+yku4si4IQpjNVQG1g0gMiewtti3KyEeyjYzTBPoY2cgHrfDJOTzAJLtequb8q3T6A8pBP5+Jo/kNsZ/zpLEshnymJEw
# DATA cbAYB4txsJgdwmLOGDPWQ8KfadleqHl+Lk71cxnnjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gw
# DATA jg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MFeGD9No1jq10jn5ML1erxL0rhEfprjmvBYdxs6Waskr15v9arN6VGnXfkTf8znSaTab
# DATA tWA+O+sVr9wqUYY2jyq1xo/oe/45qputjuKycFlKWUnBnQiHpZLTlai182VcqxUi0gnbzWKAlUr1vAEGpXal2ZgLsFXZbgyrtfJ2
# DATA Y1iTqrO9GNqFQmW5hTy0CmXDAJeUslUoW4mhXShbiaFdKFuJoV0oVQl8ey1lwwDPbilbiaFdKFuJoV0oW4lhrlDqte22lA0DPLul
# DATA bCWGuULZRgxzhbKNGNYrVltu50u5XC2EqC4kKveLg38jrBZQXI12za8thKUtgo7V61ULOibhJwYJZhkpOtQ5flql/nwB1FttK4B6
# DATA e/MAckloN54zCesFsAnPTGw0zTMTc8/imfm1Rq0a5nlmPf7P5pnR13bYy/HMwlbgd4KMZ9bsNBr1huGZBY1u2W9lPLNWt+ZXds4z
# DATA U14PtaHBzITEGU+2JDsoLO+FXqQ287MWr1QuWPTPh1zkmP0wJCM28vckJoW9KAuCsx2RvMiTD12t+54dDTN9WbxLTt9Ok+PDcL2l
# DATA ovo6i9NWqMVVZ9tnoutI3u1ckYn83OphuWotEqt7y5W8F0ZXV95j2feD+JgXYrDiVvJ0nbPyts0OC54Vm9nckv10ehKrcru0nIFm
# DATA 5+kZHg0rtwp1kifLFQdCcyA0B0JzIDQHQnMgNAdCcyA0B0JzIDQHQnMgtJcbhPapqt0RFdwdhTLDZ0r0HidJXcTRPWSE3C6qm3eo
# DATA Y6M6cwNVK7pTuh29xk/cjm7duvkpLvJtt6PejeNoRNYV2WEn40n8Boz4+4BiDH/K4dz8VLeg8R0GrTEI5Eat0q61G81Ku/EqR+nm
# DATA 9/kfFYXOHdiAP6HZe7UiHW/55u0g/lTeUXzFjc7N25+xbOaNzt+U/vb1O/Sum7dF8g0XvsdB3yrf/iwkY11pwVlxEf4bB3hDxeMm
# DATA 3a3UR8dTGvVUt/eZRA+V4476+WdxNLrBvRXlIPhwaAy31I+yQHvjhr/XoeLwb3X2yHrMLHmV2kF0Z6k1O4hQMIPIrpB3pHlQudGb
# DATA JG00c8Rr2caXGQEOkKPdj7GVYBTcGEQ3b0se5X/nVWmauKuu+PVy6Wb+BgzBKj73cO+BnJ6myvaZRtaZo59OWcUpq8wrq5jDwE5d
# DATA xamrbKiuslQUeweqK/chx6UVQAYx632wZpcRXrlcIa+LoNOxKUBXxRPkxT1OzBlYOvVQ1iOp7zk12TkiXdkC0jVsHF15BYyOzRdU
# DATA fXzA/ANFUYDRqXsyGJ1+aI4R15CgHouJtJwlx2PS2/Cun3VnWdSAyQI960ZW2H14HA6oEz3j3kpJ3TsiE7hw7/roOq7eaOVcoteW
# DATA WvdXmtEg41FK1kMYGKk9I69DRpaRxRHzvSi1wyS59WR7WMTGS+NpApZvT3Aq0N8WqxEaDhmfTrwWZCSOlIwPJfHEU4fujVgMvXNO
# DATA LaZffd3W/6E0ValgBrpQ2CKzc9PaqKtKYLAWbe5FUAzJxhJndDqjc97ozKwLZ3U6qzM90568NK2/B4wa4kiyixvIUVR/Y3QaINkw
# DATA 6iaxJYE3ZQtV6d/51LpGXdAt5rXvzKCYtSg1GGpICUvJdePhMEy6kR4D2XJNQqy0YOPC2tp/nLLx6w/EW9U5gc8sxC4TDKMGoCTs
# DATA XxpMsZdigf6WOu82b6Iq9yxqIn9SxqmyOfSPmQFkrvDBZ6DTQg5HxU+WG0RwUEd+oe1pfL7gBKnPecvTusN0lPZTc4YdnKZoC2BN
# DATA yX3RKjtQG+dvsQG37K5uDOIGNZcjvvle9nX5M1yJcPeH+LDCupSBWVt44kK1TRIMEivMu1wJY8+HNGh1tDNDOlCnZNgd7LGW1R2V
# DATA l3ZeFHBAvBvGtHNxBnNtSqZ8e+XPn/8fDZOKYrRVzipTTElVUgVJJidijJF9xyMTmDzakuRBiKZ9+7C7Ap4veneDANJ49LSwgLpo
# DATA bFT7eaLI/GSwV/Agm38yOjIRRROTYZvSWw68N/1RRgUcBTIplZ/eAREGL6mWaJA1lCB97ORc+VqoPefI3try7M3VRcll2Mtiw1NC
# DATA Jv5A5/Nd5snQIDHek1zTE2vONR+bACbRMLShbOPBlGfPNL+cikXPBCTl0ffuRkPkVY+stbQPWBWb3rhUruDrOE7ZRD/w3gZ8Ea8J
# DATA orQ7TVFAHJIsSm4jl0172zR/l+etark6V9HjU9c7wQedp29hb4/vVf/jt1WwkgLKEywejMAzPwY+iOrWlPKOykKm+KlXpgJtw2kh
# DATA 6y/dkOYgB96H1GXT1PuuVGypviBAMSeJzyt6cG/c9t6078AZQnGX8ExabfI68H5EX0OuyFT+W6vI587i1T1ELps/ooGWJhkURKLz
# DATA 2JizPWr4+6LnlLHAoB1I9QuVaSx5KCs+qfQFcjcqKfw0vkKPY0IoD34A7VKcDExZt9Q3gfgjDaXak5fRb1hCkbhxph9GInkKHtlR
# DATA FFMLUQ/70vNcjc6jsVHn8Z+nEa986sFbF4JkMNVfGuNQsbkCsg2kDSOZDiHbvXQQjSk/uXFw3wLQGU9vOqxvqj2CUFDFqC5KrNw1
# DATA eYfhRIqOsxALiWk8DHHhcBpyx4Gno5FMVKhfmmyl+9j94HePxyUwkSJTtU23KG6NyXEsHbJkLXrjVBCaIpQcRgmNbscIRddjlrGN
# DATA jMIvTdfR9BPV8skWZFVnvJO6JpxWpN76SE3uKGw8MYyxkMtzB/QUjJ2Q7gU2azFz8+aKLBvb5oq5Ipn1OjUwtcCrhYRl/BZT0TJf
# DATA qbn1ueFJoRycxXp6EVwu2WzLuVycy2UBQcF5WV58L8tSB8qVIirkjgrMj5QDm7XgDaIJjjizEgojMUGxVKMJu2CyB/k8CWfsZSMY
# DATA rrJW+Vn8JOvgh6xK8tGX11+jjrTY3vTR99zxupac5bPO5csFfyDdYREnMXckXdpvN0btkLedjLo6KkrlMfO72WL2XB4LwBzWc/yF
# DATA 06NWYvqV1x+wTW6qCCDI/ujErFr9KD4GDvlE1Z03PL4whXeKrKo3vHt0f0idKYwhGCGZJfwGJmHRkCvcKD2W2cMEG+08Xjpm/f1I
# DATA EV01mwowWp9sM/BxoV1GhlcnfhzO8aLyteWdiIGZ7ICk7Jh2J5RIKfaXYcnJ5lzGzOO2KZf/zFjKfwVy8vQ3HoiUs69n38y+midc
# DATA Fu78Uwa8xP173ukXdO0p/f1s9o13+qvTL2dP8ATufYrbvxUEJt3+bPb16T8AXunRh8/ptj/KrY5jeQ1MNi9lv3+iDiCavh6J5sk5
# DATA 9wQHnuyW99KpTFhlQz5za+VBbsAYM3gwYY/ASKZRPUxYucHBT4alhT5vnl9BsXxTZMAEleEQlnkTThr9RQMsC0WyO3ol7IAjq7tX
# DATA FY8p6PJT8QlVBc0T91WVRBUcwSO2VaAl75bo+yn7a4D+UY5yZcE4qOW6Jbh1vOVd2KWHYqsYdvQed5sBHGwaEGT6LDG034p6vaiL
# DATA DfnYtiw7bkLNANe3jkIKg35OxN0/R7Rcqw4uN0vyreuyuJZrJcIBLt1Y/xxjvcZbbj7EvyQemgsa3rc9uq81uG88tl/Y0C7VMpcN
# DATA Geby0trNLiCXuTRiSu7nE4ZtpZIABDscT2QoHCfoesCp6/udiBf+JqkuNXri8BALLI+oGqQyj6d6rJa5Md2WkdmMwIOIKiSWv4Tw
# DATA l0LxL1kXcYlsNExATBso/gPq6nGGDWsgCu2oY8/bXuewkqom7eeMBVkQ4liyRApCQR4iA7Dyme6Pw2SfrToqgemQe9nblpmAGxHl
# DATA fTLYlpoNjoHpGJiOgbkTBubaA8xaM5kN7OGLM+3PY9lvybB3cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfH
# DATA dHBMB8d0cEwHx3RwTAfHdHBMB8d0cEwHx3RwTAfHvDJwzEqjGjJz65xwzHbYvkZwzNzK81pkTAv1Vq5nlMVqnirWLGR4VX6XHM8j
# DATA y2qtRqm5IMOB3WxU+rXacL9W88qtvqDOLPBYkUaWgceqc9C3khXXAlJtLq6lxrK4djqNVt2fi2ulQnFtNbYV17YV12ZrZVwVzG5h
# DATA XGudFv+aj2u1XPIqVH+3E9dqayt1oNltNfzyXFxrpW3WgVpzK3UgaPpBY76+1trbrAP1xlbqQLPR6jQ7c3Gtt56/DljBUWi1RrPf
# DATA qJaOyo0ftQp4XOpQu/XzQeyoL9UQO+mWLYhdrUHdRmsNiF3Qq+chdrWwFpQyiF292ag36wZi1211w043g9hV2/VWs7JziB32UO3L
# DATA 6oYeXWsWv86i1bXY5szu34xLV3S6VrOl1oY4XTlkPqeyni+1scqXqueEWaDzqzLK16ynGZgoqClXuz5Hh4NPDQtO8leVfzdcuGhE
# DATA dcprCRlOKkMtT6dTtWYRZe98xDhZMVCLuAuLwLj2iv6CpbA5qwRW2KbzNcbx5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O8eUcX87x
# DATA 5QxfjtUbFUqOfZ6U6O/LVz68R19f1b8KaI6NzY9feVsd/wvMSUgc1mOSGTPZumE0uMGhM1lN9DPTg4/pv9HdCW6TYNUPCsCmvjEc
# DATA Rocb0ITb4xM8CwJ/tRgKB2M9mvKIYHBnTgfRHbRfftDeHbB/gQ/Yb6p+eGUO3meOrdVqiCzyxqdZRzRCkWUBgeU+fV+lhXi55/Sv
# DATA 2YnVs9R3MkflLrQRCyoEWxZGLOo4nKGKeFcBelgMgXKV2lDKgRlpoQ+n8MbwDgbvcAooWCdkNphvqX5D94Am6xinvXfoagyRe61+
# DATA KDJRjGhQ6gpUb2Mt4CwnyrmqK/EGZD+fKcc59I5UCDyNOhc+Hsu0QqlMF1UPVyopFZocvNc2/IJVtx/ENNL11Wl12fyqxbc/8CG3
# DATA aGT6k/DYT3CgXgmKHvsDOZrvqwrqDZAQ5iSwAz3yExGmkMjnz0NPfBZJ/fF0giSZQ9BFjfL5OOpcNtSGkZQEU2y4g8AmDA9fgtA3
# DATA Uup+yioNSljLZzwNn1aPJiui9y6oNxtEDr2IiZglpKErEgQwUyp8P1EAg3iQKh6joelwMMkj7xi9EMcXp+1XRPJDec2CTHyJTqzb
# DATA oTgb2dnIRRu5UKucLJWTpTqPdbzUGt+ZXNUPI24DbCT4SuhJK9hQjj2ytKsuWBPxIuDA4txhCA6sxyREzkGlcjUeWD9meidzISPc
# DATA 1kpnIYKrJTFk16AEi9cJyF7jYOJL7BLCy8+IsH7eRNhcyCJcXxxhiaOKcrkY5dLyOLNrzK66qFo3+MWvimfq5pnZnKcw6+9ZnCsL
# DATA 41w/b5S1w4xueH+xz+2MGGcBmEhbl6y8XhhtK9aq+uhI13NxXgpEfnMaDQJrRENvcX25yO/LMCyjuz/moze8gK3nUgaczL0XnxJR
# DATA 6lCS/D49FILHddfrhcfs0mbH8cR4VKGDtUBI/jBhoToz/o/CI828MhJgP1H9uu4KAVzzgUXH/lk2yA+8vyZLIeB5D/WMVjdLZn+A
# DATA nUGiuqYZmeLKlo6UGwulSN7MpgemdDTNEA5cNFk2ZXuBjXB7dHVGuDPC5xzVc9aWs8OdHb7KrL46srFqsNPNgH1gaAu2CjxwOzRW
# DATA mVZ4lA11SqJ0L1Mx5aHGCJxCrxN7qzDqIPCxSHZieFVORLS5ngBR0mkkmBk5DLJMc/Xc9OTspdywIYHfQaXQswganQPHT16Hnzxi
# DATA HyqeEG/q8jvFnSxTCHxaQU7WbkXL+QeK7dUnKGe5sSFG8uFyhKTOV4FI3s157uHSpioDKG0SopgKwNQkPKQcM/5Z9sMKEov+6mHu
# DATA rNRnqUamfCPdNppENGGWFQieKx949/wkOYEoazzKu8cTn5mNbLVOkhPlJWZRVuyBTCRi8JnHI+0nV5MHu5Fmqz+6iWSrS2YPpIzy
# DATA K5Jv8lerKNIF3uzLDdMH49TMRJ6LFZpV5Q2L+e3lxawbhSpm4/TPlmRkrwX3GLqg30MXCyPHFyZrQha7XuVILWS9aAGIUjQvvUjg
# DATA 6SA+HpyIJHTCysboXDEWmaUeKnPewIcOsm96xecqwtVJu7BCzPUyG5bj/RUw46y/0i1W0CNKIjkJwWKlIWcUKDFwLklNAsvaaRD5
# DATA NAscsoHaCycnNJ5OkceRcl75uiUr3JiZzPOiC42uGR8tNUs4NPg+xoyUfW7sAcMCYSTAtedum6sSemHleu4++MHafTBV2AndInTd
# DATA 0Bsxezt9dDLX/2q2jRQrrBoRmmYjox8Oo3TM2tfee9xj+uwlGPjJIWSlocw4SjWn/jhOpH+VtiKda88HIhluga20y8Wpuvrd6o/W
# DATA 7lbV2EX2FeT1kVRfDVSBrwnWpknKuje6y1gbi2KHwtvCp+MgjoOiVHzr6HAEV49MRLWFCccKS4PD6EzGCevVU68rxczx2EbbWyNh
# DATA 16JrfWujrlXLusMwCRL/GA2EdycMop61UK2ca/oOZT2EPraFUuZA9l7sHduewYyGC0ubPN3p5MBjl59Zy1bbA7qJP0ae85FQvZ9C
# DATA e8ier1xXpvBcJXqxAO/n8tC++D7FDIHZDWm0j7ppHoH55PTz2VezP86env6KPn8BniWwlX+kf74Ax/L0c31xERbz2exb+t+T2Ten
# DATA f8+4y9O/YyjmHwWJyUF/TVd+xfzMb5ic6Z3+4vSXAGie/oLpmBT27NvTf6QgfkH//obeSSHgpi/ohz/Qz3TP7+klT2ffnf7aYTKv
# DATA haMU29LQXaluUdU8Djr9gfiieAjr0PRgj78fYrM7vKhdIOsUqOXIZ8+Vb6YIxufqe/DCdfsH3tuPxwOYL9SZorAQa2XQZOrAK/mZ
# DATA 9wY0fklLRPwcQdP2oeo+46IJmnOFsjuGJldKcxe2FvKauvIAzhE3qWpHsbn9AX/1INo1HUAkbJsAzSiVqMB7KDsbQ5z59cEPOgkn
# DATA jp65TtntgJzJq6S8Wh4NMdVFaKYCqO5pEvIRtS7qMR/r994P/XSqlm8px6aAQjFdASVHfaXxPafMGfIm0SBULuuE/eVkIAXTwTxO
# DATA c70qudzSKba1yyJqrpcOh9R0dsEu7ALN2jyPOfBSLKdemCmwfUtgLUNgIzvg4swAqZeFXLBxm1etTe2Cw1lIPicabmpmF5rIFOGb
# DATA WqE4y5wjODEGisdpH6Th3OKlZ6P8lwH49NuQGeLL0fjK9FE46cLvvS6OMxvxLYuBIpdmw/9Q7IQA+/KgGgWFGoqvJyHyyZqcPcAL
# DATA 3xS3ONhXfny08zTlfWQe7+ESW0Q7FWlUQnLFH6VonbxRgt1WvllGc+hNh9506M2doDfXGmvWmgJtYjRf5BTgPDOAbU0AHHrToTcd
# DATA etOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhNx1606E3HXrToTcdetOhN68MerNarwWNynnR
# DATA m41es9e6RujNwuLzWvBNCj2iYdHrisxYm/OyeyJ0w3aWsZWa6FDxL5VGnl/YDnphaz6XwQSsVPvlSv2T/ZZXL3uVslcutfmfan2/
# DATA VfPIPt5vV/fr+832frnS8Crt/WbFKzfpSzVfGI1Wq94O5R35OFdqlSzO9L4szo1KFmUhi1oVo15thPMoy2bbK9eb/VZrsF8uUfSa
# DATA n7Qpso3qfoV+aLT2y+XWfnO/Xt8v19qF2lIOu2G5wDzsNPyeX1nEPKwtSkpNYt9VMW5aEMaalZR8HQ9a3W5nAZGx3PKqldYnrcZ+
# DATA jVJSbXslSlPLK1dKn+xTWVRrlMKyV0Ar+mGz1lgYt3qrmcWNArayuW3VjFKeFlmudWuNc5AauelpUqO0YovUSHHpttchNeaugNRY
# DATA CVthYJEa/UbQDDJSYzOoBL5FaizXu63qzkmN2Nu+v8qkoQHX8nGJbWwe0paMDSVEKnvlwoy41vqehz9kanhsbmRB6PHWWmKUX9mc
# DATA XNPrX7Hit3AuwSFCUNj2+ZdwN89BtGl62zLAc65QVe6bgRXF/ZVBIQt5Uqc8oT9V+ZNbrarVDTayWf/eQsKjGIuUZpnzZcul1gLW
# DATA YoTjUlTjmZVB25OLa4FkSsUuvrXDKRQNz2ILkyHHgXQcSMeBdBxIx4F0HEjHgXQcSMeBdBxIx4F0HEjHgez5aNx3yvvCU5RNx4A/
# DATA kjWjkY8P9Hn341D5Mxn3eEPhInEBT0hQqKrvYKPfjTIjGbtDYT/mAlFzVSsUuXJ2MCIiC/FkdZxejtp74yjshvo0Is7IwX/YQXnk
# DATA OZDZyRt3OtydDl/7dHjxiJY7KO4Oiq/W3b4yB8gfRI+lCe3R+DQ6wZJ/JIcsbfCNOfJoiaaiyQzkUCeefTR/6hlHQbnnVWenewhF
# DATA Tmam/iDcUD7bqFqK65GbON0cD+Eatc95O+XsdZSzeUcJV0V8WH4f+kvc9lP6d4VmNg2KE8Effigfr4NetsmDDUUi31wuEqlyUwQi
# DATA 38Qpzh6OdWNQyvQgsVnGI8udqgrOg+N0PrisNOU5gYDnIOrJCeZ4whSIlIcmuKAQjNcLqR4NYBDRhCWWg8ecEk1EeR7tzPNmyb01
# DATA s+RtrQlKY7LOkDf9AXQFWKuXo0uNiS+YM9eyhMOyol4P3mV6GjnFCyQ8rwNzjoZm/ENNkKy/SE7mI7DRNjJGt4MN8+Wny/NFWpSq
# DATA KdOALZOsjoz8hOak3ojmtB76GQaDQroVCxKQGcjgP7BouEqFIyGUQZAgZY4IfR6jvz860cbNJdaRv1yzjnwYT1nD4mfTwyw/tNr0
# DATA WKtPx8MeNo0A00CdwBjTKzQIphkpjFFApgYNZl3KuEE/nuLE24H3EBMC1lZgpQSx6w4H/s+NUMdzqs9mXeGG+fPhCu1Z3alKDtH8
# DATA 2hvrS5JDHybxEeoApZlmN4ehQcfyJjmqNP60CxWOuyNvOkJydQ8DgWAGogLLNIDyPqSieXH5EtvN/TXbDVdqpdxiIWtZkWEYT6E+
# DATA PoVSxUCMh4TPyMLfDypWEOieBUrLkXSlbJbZQry+VBfqr4v5cbFSti+LQkNmZrtJuJuErz0JdzPuF3zGvXQyfaUl23gfi9nRIlRW
# DATA 3tXy+mvUoIslrPdfIrlmW11LtlJam0Plgj/gb0X5s7l9kVJhujF2DsnLTkZdHRN10vj1H89tq9ST/Hl1Oesx/sKpyY3vgxzZC/AJ
# DATA Zr2w4lhA1ZMm8Nq/kD3ER6d5uLmiunXXSc5pTWFbz2ypkuqbMxzMBqoVhtqff/tP2ozgV/YrImUnFqQ3CQcDnroo0IQoev0Q9mfq
# DATA HYqV5U+YFhFAhY1mLP3psKOLy/eS/smkP1TWLBusPDc4jORnsfxYjAzTZoiaWZpfHu95hEiXkkbeo9xKwkxwzqgB6hVowQxl6Ipj
# DATA P5nT1M0XKEONjOHIxKqXUFbLCsZZbc5qW9tqm6tvbu3ErZ2cw2JbahzuUnyXAU09paPPYu7Ia16Iz2nwXr4g/CpDAOf8PHutZW7p
# DATA RGxFti2D3LXcmoYs9dPld6j/5bPffMW70R2eBbrXj5ruzFwwKwxyQKSIjC/nQfc2Mr50UF6+/qI2FNiRlUvrxNY8bKKbXTHxbW8z
# DATA umrjBf3+vtb/ncSTXJW48b2zom0CMdHOrpyRzSUr3tWV0Vbmq1kwk12pvMolVT7kLR6mKaQWIgo17PXX5EywirPanmw71bJL0v9E
# DATA gqoa09itjNhXJYjnhD+JbcUorawLsFWpf5Ka/SVofMa4fV+cqUapmZHDx/1oEGb9RAS12gn26iQseWtWOqg1h5l4M8sDqxVOmLiy
# DATA cUW2vpGpW6gCeqeVFyhUn+kNtHYwulSr76FUTYd0P7YHZ+GwnnTXH0E7eEwJiHBO0U/GvNDLnmOgyOGuPO6HYsBnHRdSBqFp7td4
# DATA YYuMjgNPweyQQiM0nU7H1PUo/eC8uPSrnO8vi/VsQbh4js5zCJvD9VtmcD05/VJ4VyBnPZv9XqG5AOcCi+ureQLXv9BtTwHoErTW
# DATA 7N+scOgTA7a+pXs0ZOu701/P/t1QumZf0Y1P+V1fn/4DE7pw0sGb/W72ZPZvVGn8gQNuXQv7n417a+sGUIFJDLzrEP0E1zdjxzCp
# DATA NYU8OXVJrN5HPeNIVL+PWTdcli607Pae4oYeorH3/Q76KZmtixo21xmInXdCzBBWwbY+ortMhBxqK2f6Zz3DRdO2CqWyO9aW0L4N
# DATA /4m3ZFtvte78WUrFrW/MV7BtIrZ8AVtpuIJaIJTEOLzWGcW1dbTWhz4ZnfiZYl0v7ZVKJR41KAOoizrwPqQBxFg9TLDgSVffH2Mt
# DATA WO/8n/id24ik4KhTA6FAcYWPaSDA2YIiQ+vM6rbcTMk3nsuCZ52ZAMfNcsP7tod3zczafFR/OZx5Fziib3tAX2s8X3s4v5DRXGpj
# DATA Lum2j+4qtaFdMLJyCWfET6qY7XYyadLtp2rRLMCiWQeWuY+dxHuU0AhIH2o0ESVhEIElNQr0a3t+NIC/suuDVcRsoXyyMNr6JqOH
# DATA NMDpBeZolI6RJLhIqYWsS8vKQmbNgFTeR/FnShNvRe9TnYN7hS7ymXI+bc7+jRFW+HgOO2VC1NgXB2wcMDJLzILUnBWnFD04IePt
# DATA MTxlUeCrk+yhGIZhin2IUdrHOqYPr0ZXuCtIV9TDBsRuPxz6Hu98ZwrXmMcih9JyKC2H0tohSuvMMWitqc6a5vPFzQLOMwnYwhzA
# DATA obMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw6y6GzHDrLobMcOsuhsxw668qgsyq1
# DATA Wql+bnRWrdfsNa8ROiu36rwWOIszluPS5owTNFOpnJOjaJRb+QyvttvLc7xUbdfmQU7tCiOpVFAWXKpZarXbnUVwqaoE0o0SlqBS
# DATA L2tYbKkqx5MPzLXyNKmgXW02Fj1fr6/1fLvTbnQWPd+qrfN8K+w0/XIxE4aVWtWrVBr7VLHrba7elWG1XN8vV8oeX9uXa/vlcnW/
# DATA XGvuN5teuVW2g+YNowU8VytoBe1FOci4sELNb7a9WrVMFR6v9kr9dqkQnMm7ueDa50BgcRPSCCxpjRYCq9podJqV8yCwSmE79C0E
# DATA VoUCamYIrEpQCmoZAqvSapQb7d0jsGgmtE+/rzVpr1RorMz7rXIjjYx4OkSPD8gZ7pO24ZTxqROsA0i0a2VRIN508GnBZWKNAXN3
# DATA +wWz35jiLWWKZw/oUbs4D1w059NewhZ7CWV1EH7CBYttjXwi8gsBMkf07ImPMuSyJ8wwuGDFrojhWujx0RU172FYBu0yzmMVHfiN
# DATA rekXfz8jn/IvaiA57FfMbT1Z/rwZp894zZIp3HKsl6nga+G4VlXe5dP6QmVeVCengzMnlxwFx/lynC/H+XKcL8f5cpwvx/lynC/H
# DATA +XKcL8f5cpyvl4zzhbqgTsiHwW2b+jXBkilnBFJ3R+p6PE26ISoI16rbUY+NTNUwX6+XYPBM+oAVvJ0kMeL4lrK80LzI5KE+OjmU
# DATA Ptm89k7BmLbmBGzC7mFysSf0L2xr5HK4KcwxEwh9p67i41fYrhHz3HsnO/pPdvRJuqAvuHn7M7bRP81ig62WvWhE2aGoZiwjqnQf
# DATA jqzg76HzoeYKl+oezjEOfTlDxaWOt3awR5nml/wiK35KUJe6GpyE+iA29ql3jDOLyvqk3ziCVK0593FqZ1//SL+8scru4DKk8snS
# DATA dSdL2c1Pc5ERMSoTBy3SqN6E04CIh1j9tz8zxvzHr5jADxA3equ5cIv6KlDY6Bq19uwY5Ktyo84NPntUTK9KrqlsK9sLp3NR4a0X
# DATA DE3m8HoKiO1lybMbYkN3J8mApnz/5b/IV2wGpK83/+Iv5Ds9Snn68StvM+LhlZufLrG8ldFNXWE6ecAW+w0pVCdx79QUzqWm4FQU
# DATA XmwVhU3V7S9VXcE4YCVFItZnKblPfFS31z/QMtycUj7IOoW0ZbQ8IW/ps/uZ8oDEEg+tevABt1ve5oVFoaVP5bJDjAWr7WVPvYqY
# DATA ah1CPhq7VODekJiUFAK16tXi9ldObOIaHK7mv7dMTsiLYmybm1DUGllITdhUJeujJFKmWzRiViPZbjBmjEqW0QFh5bIUFvAxhMyG
# DATA U9FwOGE/9Z4R0JfKqCoPVxSMkqko2luaHtA48Nmij3sThislIbvRmcClgFts6Hu8MMh646PwMft4lbLGmRyjF+OcvAnBGXfOuFvL
# DATA uCso5TjNLKeZtYFVt9R03JWW1rsi2EQVW83llROBq3lG9rloxcaLELlXngWduTrpr+mdGFpxXN8G1XTxlOEyO8tyAuuUkYMBe7QZ
# DATA gIC1Yh7d/gIuptvo0+TTD9QFZVHLtz35h93i6ra/Ke9V9qp/S4OijtESSXnlVKN3vcufuMrmEcTmFtO3Zg/NEYArjGw4jj3eSrIC
# DATA PFwTwxvcw8Kdc6DgpWLyxoeVVZ3rqyOPKY/ISykbaZHE2dQInI2l1ewpCbO/9I/8B9LFKjUzEFa0GxTNROUD670dj/JaaKKa5QPS
# DATA YrvklD4WDZgQPRNE0uBEOUJNc4fClQhw0dPHON3FQydrTlnuvwPPFBdGRLKRp93JVFGYBtEQF3mjEQSrIBLHtAtod6U6KoWKkE1F
# DATA bDM5m1pIaeVdp5hb6hV+4zpUcz5Tc86WnX8xLNRsmHEmqjNR1zJRbVvEGajOQF1peF622OsHuUYywkA3iYYZlOmBLJOyAOqeRQGU
# DATA 1HlvaxlECCzi+A5nF/2OphLEPFZDl5PVQv1Dihe2nI1OjB7kmgquHF0TGyFBUS2AoKMYBNRYqd2HrG+JzmOBt06dOF5gqcoeBVQw
# DATA /qToQMqS0T9mxpW5wtITQM6HHI6Kney5Md3SclaR2fjA0B/5nLcrrTtMl2g/NWcyYucARkd0jHJftMrCRIvUvuTld1k6toJxNF9X
# DATA hBym0SGn/S3+tMJ2zbPBZSeBbbAomvkyszFXxthdLY31HAB2nRsbAtg//Ww5gV0yVgjsmMSFmpGunPYnmsT+EFtGKeXJNJXtXlwD
# DATA R6ydqoR0MQcCmVOvQEfYhOFjA4XXmZKhqxRTo+6B91bEAqtTFtr1hlHKs0fZ64LtSkwR5U0gco1bK68MC4kBCCJ6XaL4bM+Nti/U
# DATA oA0z+M9//+3yHM7VRslolnRNQhH+hV816kYTg7znXzL6EmvfklEtWqrxWJ+6n1BtS1jHF4dXJ5HY53d7fCic5gbDTnQ4BfdRuX73
# DATA dHcnqCihP/pk7LOEbxTwbzJh30aOnrOuDtP16uoH/lCqAqSss6yT2oIpDhRsZZ+vqNpCp3oQToDEkt1N5mmPMR7ovRj0cQK0rNC6
# DATA RlAGRIMg64+iQ70nFYXaoGAayOVXv/+8UeUT1hnHnlLxyTSchjr/3sMMDpM2mkBnSszHfsTOHL6gjpuHAEC/JQ2S1ySk4qRZReWA
# DATA kfU9HC3g/KQMHMGFxAFN5ClgekNQFGmoRKFtpeqZrn3DjHx3Rd1Tg4TkYXGF0psk/hGNm8eUBp2Z99VRgr4SyPalWiZkw4RBqowC
# DATA 6uVGEwbHISzYJTI/oYY8Mj2D6lWH1GukPJeMIPFoLatmcLlJpOTcQ5r/ahVu2H6Xmq8P183Xh0zgs5arcL4xa91qOSwJD7EfXA6I
# DATA UEJSNWRgtMnU643kecq+iswyDHs9zmG7H/A7KYtX0wyN3Ttyj6rO6E3F6ovQ2f5MdrMWMjRvJMieRdtIMFcke8iu1bsL9cSOnS1q
# DATA 1x91RN1+DP0sH/5SKkldEC/FwpuN0aOSCG2C3j/Pnp3+3ezJ7N9n353+Bty70y+AxKO/n81+d/prQeN9Pfvq9PPZU/w7+2729PQ3
# DATA 80Q9Oxxm5X3BND48++z0V3hq9g1dZN6eoPfo3z96dMuT07+n5/50+iVweohBJwmP9w1675vTX9C/v8HPTNz7o0PrXQdvjdQ0mzcv
# DATA U85HEVrpSLYFg9jwE+ObEeV7mGNkMQRQ+mFLQdY38PsjvZ0kCbvRWNlc6RT9Ebf2Ycxi/StJevckXlYDcjA920uD3Llojt58mewO
# DATA pSdVJ1tJvC9VSSRPijejJ7LWHMPjndCyeUf1WB26oKyQCSPeNgxHU8fTW6PMto7UE7Oe+3LueuBlFr9ZhwwI3buJPc/d2MOsW6Lq
# DATA Gh8rqI8mnLPOmqB/+dABCi0aDnFGBzAhKmwDI96o/q3AABcb1WUh9s5OhGPsuXH+Ocd5jdQ71/D+kizAXMjQvoORfa2BfZNx/WKG
# DATA damSxRyw0HqX2XR2QdIrJlUviohL1We5ycKImNpDIuI/NybuCRRLFmdljVWULI7CSTzmZ8KUD7THZC5N+nGQroPJu488lGWsYowo
# DATA e+Eh4I27lPxhhA0mMVll2LMlA31WXeidfjpNAAbzWWCUMpn9+XvabZ+EaD+cohMuGdHBERIgHCtMqtOVIfUHgvvqwlmteWaOhudo
# DATA eI6Gt0Ma3jqjx1pzlXWN3Qu1289jtm/DandUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfFc1Q8R8VzVDxHxXNUPEfF
# DATA c1Q8R8VzVDxHxXNUPEfFc1Q8R8W7MlS8eqPSqTbPS8Xr9dphcI2oeMWV57XAeDnqW7VtUeOqpaqhvpWbzTw3rtdttVXeUAQjGllN
# DATA ENUsiFqtlJVNRWh7cniq0s6F16xVutXuXEFV6mWvUqn0K83SUblW+2S/4bXL++Vq3WtX6J/Sfgtf9tuVBSU3j+arVyi0eqlfa3zS
# DATA bHrN8n6N6kG5dgZ1zgQ2h4mrNBdmQMsi91HkrcpZrWcZUM299z/VupVGtTQX5Wqj5JXr5U/2Ka01qi37zfKwXqO4f7Jfaesr505A
# DATA uXIO0B23Cg26kwZmge6atWq1VlsDdBf0GnnQnR+0u7UMdNds1NuNugHdBc1uqWOB7prlarnWvADQHZrU/mp7w+Phxbq1yIf7YUi9
# DATA QOTvScCFxbw5VFyVF8yy5bJ80MpumXNS6Ryac0QW/P12WIs88BsNqh773kpsOKln1BLYwqQbt+p8JI1ZnkfIqbAFXbd4q0CRaDeP
# DATA WVuYM2bg06tfpVU0uDVqwa5MEYd2c2g3h3ZzaDeHdnNoN4d2c2g3h3ZzaDeHdnNot5cM7WbD3CTZfGDrjoDUApxye+Xm9+UbLzky
# DATA lkshz+KJP5D70aJuve9P+gc8k7zBF2/eohzAcVR6j3KijaExMx3z7Tdy73hVvtGPKfcik/gdbMe7UbZD+UgOk1mBFN9ZCIafnTty
# DATA pgliMgU0RzrcIWp3iHrRIerCMR93nNodp970OPUK4dtdHbOWVsB2MPTaZZXVHLO+RCGPi6AuBOp4tqoZ+OrdOLypJG11sxuxAyMT
# DATA gFdPZX2T+p4xC/IshmHEAnR1hW1g378sOmGLBa9FHZSXC9/KeAopZjOsoRhwqFry/4zo6udNfM0FE+FyY1GEW1aEK+vHlwdVUNo4
# DATA HhxNunJGJNVDmW6v+p7jQMzFsGzFsGVHMB+9pbyHe6pFhUY06PriHu6xlcfDGAO8MDnRB5Lf7UFlE30IH8NPeaBD20vJLBnvsU+T
# DATA WukAXv/BiQclTVSyCLw8MYrEWy90Lql1fG6cmqEKMaAgKECYOX0dYDeG0aNC0sfBmT/BNTlMJ1h35ykVSzAN2SK2RABwGpwVGHkZ
# DATA NcBJMk/Wbm7bYgAw2dD7pfEw1B3RezR7OcIMqc8ADG7fXewOVglCtLO+5mxAw4tzsNhBYp0lu9qSdXbrC263bgqFvXR5IF4wtxaC
# DATA 542+QU4SkKk/KYtuK/5Bh4+RwhRZyVC9dFWha6LAsQts6pwC0rbJqQvUpBbDU9dTQizUP2S1TVNgEek3E6RVDeus2p4pSPOeHj0R
# DATA mqYCp9L8VLbFQsyzgpOcpIvvYaPEdKjsM1Qw+pCGylBCYFKT8gaKQie/wzcYo6Qowc1xvs9irxLlkLJYx/hdM1GLeA5IURU9o0mU
# DATA 7LEyO8dGq7LnLDSteG/jA9ggRVBkBeAIxopof4iFudWxfgDoioo1b1MKAx3xt7XEVUCzW8SGksC5t8dTvj3vBJtlRdUJPcYkPgyh
# DATA YnXgWUZ1zMqiQ49BBYr6siy6+oXzMX6JBGzsPslZms7SXGRp5sYp5zF1HtOzDNTLF6aUGKRKWTGJ4yGr1HGDyOQpBwNpKgtFEg9U
# DATA Pd8TZ8WeDEbQnUMzwvo0U8HYs+LJ6p1qV7yMuBkF7B22EpS6o7RJtdzIYaLnGzN2Ey5gf4ANDCKQ7aBg60DBxOKyTatldxo/N9Nd
# DATA 9Jfl92uVTs5V9Xn53VrGM29+XH2MWJZ/G3Jcyj8oN5ajXHRhCMrlx6OQOpMxuxb3cWRRW4ZY3yjXvUN7JaNSK9EF5Ub8KFQEMpqC
# DATA YKvc4GSP7Hbs/e1Qvejh6wTjJULGHpIUax5yqiPlHgLG1rGf9kVLVVvodGkwSLfBwbmQ/Ht4HHP+BTROjfO5Vy3lc6/WsnLvAS/U
# DATA INnc16pMgmIpgM4TlqMUaUy5S/zCgxD4ImzW9dQhXBEq3UJu5drg5hlWX55hVoOWPPsh9akUu3cSnsqOZQKT5VulUOuqzbqVbxOY
# DATA UrxMxoZTNJpOMORAtHSQn1jxiMGwHqp5NLtSFDwzCTvCjsbBFci7xgZ5dw9VIBFZiWx9MJd9hWpXrZQK2bfHU2k2UQ+lKFKap4pS
# DATA Koh90hqxHz1I/GNs5dVLA6w3my0NPE+e2X34hln2/vL8ykYDhfCLH/nautaZ9A5zKoQbAXSf0AuPyOYwZjpZuI+o4Q0U2ilg1eFh
# DATA HDDJz+tjHdi7L0LBzLTCFbN8YlZlUhroKddZkxctehvZZg9mG9e0yvKMywZGyTjjGMgbaDoPH+Cq8rqMvHKLalig88r3qg3eM0QV
# DATA FdsC2YVA0yXliBHbjTHyXNdi73AaKb4Xc2OV94bNRt5yflURXi+KQyLDePWiCSRmbY7X/zN7evrl7LvZEzC2nnqzP8y+nj2d/evs
# DATA CaO3nswDu/47/fS72TMwtk7/K27xBMk1+9PsW/rpm9MvTn+9h3AoTArrO/rt373TX+GnfbrjKf3+Jb/p6ew7evOT088ZDwZklyKA
# DATA fUlf/50CpJ8cs+s6uFQyqB+6zKHNA5I+JI3gA6UmqXGBybQ7YfV76VAow8KJwBePMP2LhuKClHYLF2oPp8/BAYBCCT8FDiNvROXt
# DATA nl2lkR/7g5UYr7exMh74JyamjuNl+1pUB3HRIK8FpbI7kpeqhdmS0QNVLQcRxTM5Kd4vtVHf/G6ukm4T5gWXoYqJaOHLzvxQx8sB
# DATA vdYruq0zvR6EGeggY0EkgKTqLstQObjkvBS9DfYCiYwwQxXMKWJ4fk7w9cD7URTo2TH1bjK9FueUSukc2evsyrjcnplvZZeF9jo7
# DATA FQ7t5cyB7ZsDmvZ1PivgpVhtuSgLYBcGwFrj/4bD/8WM/lIx53LBgn5dsUa1Cw7YXPIBNcXaUMqc99Up2+MaCNUrTkIxne9O1NYI
# DATA 3gLBIiGRn5g36aA45bLghOJUroO1yGAP2dcLfxA24KRwvYWJP9hTlhwNaFEwRfGFARcjjLWEagivIQcZ5okjrE0Bs2ME5gEFKi4P
# DATA OKeojcM1E432KYsZxO6RdTGJRqF2VPHyGULHMjTMlj2xWejFYocYEJSjhDlKmKOE7Y4StuaQs9YcaF3T+WKnAeeZBWxjEuBIYY4U
# DATA 5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhR2ZUhhtU414J/P
# DATA RQpr9uq9zjUihc0tPa+FCrPzpVz3quVWv95oF2hTDeodW+Ei2lS1JTnEZSRlUGNFSiFllcs5pZ5i2VXKduE1cvlv3pkLvd4u7zD0
# DATA diMLvNbOBS6pygIvVxs2BCwXeLvX6nR6xcAb9fbWQ8+B3mrCYhNIWbmRgd7qrVwAYd33W9W5ZkGPe+Vy66hWH1RaXrl5BoFseZ1o
# DATA ngNAxo1NA8ik3eYAZHW/3VgDQJa7AgBZPej2ShmArNGth62SAZB1e91KEFoAsnqt227vHECmG+hK+NRBua4pZLn7zeioFwjq69DG
# DATA 8kFo3ljWj+ucmnNkWo92sCiz4Jl1lwUOGsoCqdiOh8rBgjXhMhtEuTfnPApiGeA5nr8Yb1K5TnYCTKoFHsmK8UhKphSXWRYs9NXn
# DATA XlC5reda1HuXM7ukEP0W23OLuGjtdjtPQ8Mq83JKWa7c9gplscLayd9Y8D0Y96HDkDkMmcOQOQyZw5A5DJnDkDkMmcOQOQyZw5A5
# DATA DNlLhiFDXaBQgkG4F/IyUXCntMdOd/40JrM7TO/8zd/uwaF6FN5hC3YPHe2H+OkOquRtU6H5dBmso+TGzU+j3g156OanOmhqoTBB
# DATA /FE3PBiRhXpzX73qth38bVZ11gc3bkj0bt5GV/DxKw+zY2yB4MQ+s+Y42Eeo3y+liGMfK96L9NNTlFRW8qCJcXJD9VbQJ5b0UwJG
# DATA wa07Y7V7P/0+DLvblD4E/hr9dvNTfvrO+DafyaA40Y//G1+jeCxMTS7BJutvmwy/LbUOE3pu9FkNozx/R+k7U94rJJw++WOUn72H
# DATA OCSVP3+ZUPSZ4EH5EcWSfWLL3/5s+euY9NYNo8GNG5TUfaT55qts2gLyprKEYkJJNvWCGhKn/oDduDc/zSqMdVnibt9HGWdz8bIa
# DATA pGKJXJUcUmPBzU+zDEPRoTgjysboNUXOY0k3pDO6dUvffDCekmnyqYr5D+ROnLKj+/Y4IjSx/gin7v78+f+pzjQCmxfdKt+kLoYi
# DATA MRf8fvnmirBxPNIO+z6OS/Lyx3zon2V14TNVR3gyqdvkfFVWD9zO1f7bUs/uYAarq551w16lXsq3qGQ6EilhIfRxdeBWRhfeWGXg
# DATA Zm1ePZXgDOlZT3H52t2FVfOzHCj0M6uaxH2orGbtQSUKUdFJMnPABdHiMyjRgOZDpk/VNdA8JmPFzVykKdjjaETTxUWBYiWNHgoL
# DATA meSYMU5n4pw6E05f4sXXl9iUJHMVdCd4ZSXnr1+Nk3kfh+BB5ID4qj447R/iVZN4GCc0M1vJlLmKohXX5wj3Lkgz8xob20bNLBIx
# DATA OSdrxsstEUmV5hW218slLQ0smE0jJ0YvU7dAwFPqSSbyYQu9PyKrbE9cT6Jlj8gby1tW8+IxZpGA6wnroT9NJiz1Fan3jmnkH4l+
# DATA QqykPoyI/Qqhj7OUR1+gI/q5huNMKGdCrWlCFfpXJ9rlRLus4Xep8XUVxLzenEZgauVlq4yU1w9FF8puShh5xmGMhnbcj3MjlCAE
# DATA 9AB24N2FiA2KjjV1fJkLK/hY+Iiaoz+IelC8geg2nA8iITUKw0Bjxjblp5iIKuCDktOGtPreAiUtB09ZB54yjKXoWO9efV4FREnY
# DATA jSYS+PJ5+d3Y7SPc7Hv8afmd2txRfCH+fB3QKXbubaiS34LhuFwnPyuLHMuCvXpaHJ9nRdnIhvEriaeH/awx/Ixh7yzhoXFJ0xEZ
# DATA j6xFlW2YRns+iiPWtuqyeejpE/SwGqcsNjdm+V4YmxSHw3CyDcrAc+RffbP8eytMH3nsbLfQAtDGVXAnk16WjBNXeMo8Q9t0OPYH
# DATA jyivtHwgh4fbpgNguhnV6IUjLgMWb8MpCC+YJlpclwap7TAtsma4KZyhsjrfslYt+fYmjfGy74+ZOtPI1D5lW1GdC8OlQoZYPRqB
# DATA ZSF5ydJ0spiQKnpXmE4OvL9iIEbY7Y+iT6ahUVCkSkoTOrASJn1MO/o+10Tk60RV3C3kZtZNbZqXZ9RB3etJTn5EdYdVELVUs8GQ
# DATA mkyiNHIVYgtVoUYNEp4s3O4jSEEWTFmVez7LLirk3yBUk0zOdqUhZ0S9e/lh+LJacGOzFvymP2A7Qk0VQptFA+OAMySdjjEBowT6
# DATA SedEzQ26orMoO50PPF6pQe6yHHmi2G6Ua70whIgiplpkUYTpOOxGTIQV9cvkhPUMzSR8FB5vIwftsW/TClhanYXZUKpgK6hcibmo
# DATA Kbg07Rpy14bOXpF6zDSs64PKQxl1TAY2THXsoPD6ZBGifiHLWAWUhQ+pUkMH8ghbxdQemysLVXmBXBtZEM6v4fwaa/o18jXNuTWc
# DATA W+Oca0JLXSA70yhXVTZHf4UpTtXceDcunZWxyrvBTMalHHve6M3LHNj9rU4u6mtm0su7GuyR01zRs17Opex8JHaG0Le41xPTwA/E
# DATA Lsg5JHhXC/3MNpLpdW6o7Sk3lV9Et/ARb+jHKyRS6mnTM+rvZp5fleObGAYSMu7JeOEzd7g49B/LHSU5JxeO+Wject8Jb5LhlFhl
# DATA unZU1dMmqvq7iWrlzKiWW2tHVbb9ILL86ay46duz2JkrJn61RdErW9GrrIidWhU0/iw5F8DTP/D2XuV9ikMyseVGNj+S4euvibRC
# DATA loU4FmLXwexSrs6NaXCfyHHcVyWIrCIb34zVPsylJQ4cMYloMhhYpnZO4f+vyTbt6gkqTcx7GCUNSEemDMc+De+A7YzpUTLQMANT
# DATA VKBsFquBlIpOqCZbQkk1e38tpCWG5HiwzzBL3rFFbwnAw4yFJgovyp4XRD//eYQhhd0ro2kKQf70hGzfeJhmXlQ7Zv1wMD5j4bhQ
# DATA qtnise1XzZaBJf9lzxY9/iE+ZCV+rsBkK5c0ynBiVR+xYbnEXg6r3GIdThOyicmks2mH/zfDC5+ANphnEJ7+I/6epx3+8+wr5hF+
# DATA O3s2+713+nenv5h9N/vm9O/pyWf0SXELmXEIYqEEziF7DET8ChjF08/phq9P/4Ee+ga3PZv9gcLRT/5+9gy4xKeMQaQgHfPwOsww
# DATA TPXKJhZc4UE8QY7SM3vKX8kdjkZisHCSoTtLhMki+pBKUWgEMKwMwYN6Um30jKOwS7PxVXDD+3obAw0AjFZzaENrMqEL7KLhhnOl
# DATA sju0oaoj+jZwNjRxh3+Zux/bV6wO90HcU3tato425AjkwIZRypXdYQ3XK7atYw3ffjweoJfxtTNkGAfTgQ/yejxhzZ4D7yP0/dx3
# DATA Zfu8ePELG+PpWbP/ieIwHXJPmco2KLhQ4omv17L8kaBj5oCGZ1fB5VZLsWVdFs7w7DQ4nKEb6Z9jpNfcwvMM8C+Hp/DCBvftj+1r
# DATA De0bjuwXM7BLtSzkgcUsvKyWsws4YSGVWAEACUhx/qKulVh9zrGYIF9cmgoqB9qa3kSdonh487VsK9YS3bCSRuwVLebbmkRC42XN
# DATA YpdO4i6vOPJ4rFFxzI/jWhLQXHuUmuiH0yT2/CHj33jID8lsiLoRlsZzNkHOAggf42AxAg9CeKPUjmq1VkjWAxXn+6GfIkJs23Un
# DATA cMWIkcheHaHUydq6KurO9ETql6MVOlqhoxXuila45lCz1tRmXcv4Im3885j427DwHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r
# DATA 0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCh2r0LEKHavQsQodq9CxCq8Mq7BertXq3XOyCsOgVw6b14hVWFh43phUWC971XLp
# DATA aL/d/qTc3K82vWad/u5X65VPam2v4jUqXrV51G7ncqlb7lS7vSLGjsJqLMTY1ebIhnLSTwB+7TzAr14tFwh+tVZW1nJsLSP4ha3Q
# DATA 786DEy0+YKueC75SbeeDb1eXhm6SmQu9VqqvCL1+rtDtEmmVvVqteVRrD6lr3a+1j2rttXO6PA8jbJa9ernZb9TrhVC69W6n012I
# DATA otwcOyjtRmMHpQla2MFGUG81gzOxg36v02vksIMB/R1ULOxg0Kg36wY72Ol2a52ahR2s1Gut6s6xg2abGoT/D9ear6/g9ol9683Z
# DATA RdocL7zNDJRq6vXDkLqbyN+T+C0EGNbVSlxljtaHhcW5FxTc7rbRqAskP+8mc88rww7wGvLHDpOt07VzqK5NJ2SKGLn5oF73i4aK
# DATA hQ3MR9beXKBHdLXsVVrk7ZXFlHzSKvB98l/qjz3jXk0cLGTrXjFPVpgtK5PM9oQDDjrgoAMOOuCgAw464KADDjrgoAMOOuCgAw46
# DATA 4OBLBhy0+W6SbPFiCCmNj4oj+je/3yrdqpT2aGapfjrmIrwpUzaN+XpbDsnwQTc0slv8K7h03SECDr3/+K3XLuFbEIbjg4/pvxFo
# DATA axTu63dKb3z8ykespc7n6HihBoHQjxLEAU95KMISljl8g7h4nRPcy3Q8v5MixJvmKXzid71rH2WT1HlhOoEfOfyB9+cv/z9EZi7t
# DATA N6qV0i25yuKe6BoQpEaZOYSYO9t91tlud6b7RT/TvSkp7Cqc9S642FZjwt5D0zBPHHjvo9rb2i4L4WCXejr8+hyN3AUFrHiYfdsM
# DATA sHlJgPMSwPL+Wn1W/z2mdklFkNf0QqNr8xZcj74XxPRDesxntD+EExJVi6WA+n6UHHgPogm7n7Tgu1RAES6fjuV4sirc3PF9P5My
# DATA GkO0Me7xWeRMNKegcDNXzo9CmMq+kduBTXTxSjeXdArWakHOGHLGUNEYmutRneiNE705y4y6GmI4H0p9ZaJFEBv8xc/ijlHEuW+0
# DATA G6gZRocjRf5SGmoKH5nQsNCFuEUPN4uSROoDvwr3qMbj8IZ8lu8QHRq4IQe2dssCzZS1wV8PoToD/1imZGPzYNh3IaodDve1Hu6L
# DATA kgJ9EpX0Cbea5bAvdjuKLDR/XH4vb8/lnuUhf7oO8C4rLzbkrjxYwU/SuSrElXtoFVS6YlsJcOXhcSxiTfEUgjE+5FgEsjJES9ES
# DATA iajhPnuhRJZJzEMa147gRf455FmSYV69SFSKyPaLs/HOhyAM1Q5fNOp7bCjrM6fSaNTsYLGw87wAtFl4E5skS6DJMS3lgLEBC8qc
# DATA MfSAJQj9fPyrc5fc/bVL7r4cMBcrXRfde7BF0BH6zAag4jhU6t8pk77CMavjKJZQHh2G4mNJH1H7piKQSepdzWeEx1Dti+LedBBO
# DATA FFggUXFJx/Hk+Yssl7KLK7OsN9mwzH68ilam+iUpsx9DgAj52IkpQjYgiqWJ9DqKFjQ7FEYW5S514rgY98gaMTytXngsmlN6cJuI
# DATA JDzulMUdLuljpr8xc8U0Oi79zjQ9ef7SyqfpGhTXB2sX1wc+wO28mEF9fcajSvuipW8aA/V6h/CHPwpPxNrv+FDQ8vrxUBoWJgcj
# DATA Do016kYeFVQCWhhQOeBVsQO+Fz0WfBxDE7LCLAq/PX+h5VN2YYWWjcIbltnD5WWmx3PVK4pyIK5l5SX+COzDxzBATSgVVuBAHDEs
# DATA j9xV4wR747y7XL49xndRJwQRMox7Ynni2JQ3nvLhORZPGAHtsoV+L4v71S+Ryrol8kGolOswfEzUT4pwKeeDQj3ASHMSa0OE+mKP
# DATA j3ehBZyIIKGAAVWr4f6NZ9YIAGY3D2VRqo0UlK7o322hzcwn5FzFdLGEuefCmLwMfjYrCOdoc462oqPNrlLOx+Z8bOdcbFzqk9uR
# DATA 4LRMyWWmhxEQlRs2pnGxXSLUYEfkuZwnS+89gb3Pm6yx/NTifTM8E1a/nwE6y0Ix3ZV1KaPGnYU6a6zJYTvW3jID7uJ5gdq1d6M7
# DATA PBNwJwFkgDv13QLcLcTGleWyBseV1obcyW4euAvxQRhjQkGGSjHnVcGBqB7IvIc6hDmfXbPE2C9sa/eOsZDJ+4uapeVevnKZH3kY
# DATA PkZPFFhP0S8rHqvxYz+iu0/sZ2qlFW7CpYg6bZpiNy1ZapPrC6mzXXfHfQrF+xlZnqPw5MCWfFa6ztIJwCF0HHtlbml+omBxesPa
# DATA mKZJynTHqjN1FhQnTK944KagjTteHBrct4jHXrn7tbo2v1htO/MYcEkFVq2UuN5ZLZz6qKmGX6o9ud18TYXetJJhp1C0CvseWfiP
# DATA pesbURwHMlVk1ezxNAHoXRa245T1Uy2B7DUgci+I8Zwh5KgXCbuJ35tYCLn39bX901/Onp1+cfolIHKz38+j4/5lIf6Nvjyhp35x
# DATA +vnpF7js0T9P6OLX/PdXAMfRlW9mX53+yiDhns6eKIV0KHyNoZ1KQ7bDxF15U58tc98zdcb7S//I994OIjmLJaL3al8Jz357SRSO
# DATA AupA+NtxnAwCY/3D8z0di+8UrgRxnQ1OmK4bw6UtFFF2GmQLFKrnwVPhY2powUqE3JsQ0GCtCY//Fp6E48hlMwLTKVw0R25x0ewO
# DATA Jten6DC5IINTc33V18+Cyd3zRRJ8F0A53nxFtiP9S2OCuK4wmqPBOKDcekW3daCc5JnPZs4InZvMq8x0Shs2ajI1lA6KLBddUXiB
# DATA j4Y39LtsbR9OfWoUk5D6trei9NEerB96+t6HP/HScahIGTj+TmlTqjBTtoHgWpysQZtbXEeXmzgL2+BVwc4tToxDzznrYUfWg8bS
# DATA ndtoeClciBdnMOzIXljLXNjQWrg4Y0Eq6aLMMIbC1Wxou6DYWdkA0BwWiYNwDA4VmTJmoDY5xLP5JdnSjYfDKbprLOC9ixlElx0W
# DATA LCmSUr50Q3vET0J2UIj3DxmWqs32NNJTkfH1XpTwKdo0XZtwB5BWqnyzGiZGGXJEFmEifg71a4/myhEfcOAdQe/HP6MRzePkdSkD
# DATA 497kwLuv4y0HFBQsrOgEnrNb5KyARpAZTQsmmSE/oIsD6eA+ZXLUFe8xp30k7hreyxmOmKODE/JoXQCRqSpBueqYd45555h3O2Te
# DATA rTl6netg1yqz/MJnGtvwqJ53nuEAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDn
# DATA AHgOgOcAeA6A5wB4DoB3ZQB4lXI1qFbOD8CrXisA3qIV6LUoeBYvrpLh6OQ0WpbvzYJCab2Vy65avd2shwWyWqVCBVBbQVazXt0+
# DATA 96tblU6lUT3/qyuNc7+62mp2asH5X12tnvvVjUq7Wmue/9W10qWVda15aWVdr11aWTfKl1bWuXbdbl1khufa9Wavft4Mz7XrzV79
# DATA vBmea9ebvfq5G1fp0so6164vtqxz7fpiyzrXri+2rO12Xak3LjLD7Xa94aufN8Ptdr3hq583w+12veGrn7txlS6trO12fcFlbbfr
# DATA Cy5ru13//+y965Ybx5Uu6N96irTdnqqSABD3QpEq6pQo6tKmKB6Sso4PyVMrC0hUpQkgIVxYrJY5S7La3e6xlzXd0796zTmeXmfW
# DATA mr+0LLaoq18B9QrnSWZ/e0dERl6AQpFVvIhBWySQyIyM677Fju97wmNtr+tapf5ETYWNR37143a4va6P+erH7XB7XR/z1Y+9uMpP
# DATA baztdf2Ex9pe1094rO11/UTG2g49VMtebb2612iW76w33qavyaDD+k6zUW/nPlavr/NjtWb2sToCHevHMceUA2KRy1eaiSIrrVqt
# DATA mq1Jo9zwqo3GXrXcrzW88l61nOqNnUbQ2FnPpWRvPRKbei1mU5d4jsWm3ir7QaOZZFOvbNQq1UaCTT3Frw429Z1go92N2dQb1Waz
# DATA vmPY1P2Nna5fjtnU65VGu1o+dTZ1DgYXdzhJ30Q6ZbNd06LH0daWBKztZ9KE6GYrLm/bTSdqrHOCJtIzmRM9m+3YRJxVXsMHwZZL
# DATA y2haaRlzCd2tUhdzrctwqaBlw2y76BnBxxL2/E60f3aDfsR/ZU+N4r0SvaqPENicLdhqprjFfRgX6KlUU52/JttW5tdhTvaB2uvV
# DATA M8xsA6hc0DjSXUidKEhub5fnk63bI7UgHJ431zjIzXF1R6ruSNUdqbojVXek6o5U3ZGqO1J1R6ruSNUdqbojVX/BSNVji1FhN6yu
# DATA GfuOWu1dFeyPGPjjnDBWschmW7l3wHTlAipS7EedYFOoK+iipNliUcfXBGSiCBtks9poNBt8FV6ewKaNNzU3OrvGiuJc/YZFqQnS
# DATA UTGEICYAZttsSeFhX5GNxL805QXRpIOSeTDxBdOc10ZpTKo6WC0XmvU1GEc4qLJ65sZN9efs5k9/jH9HXMytM7sFGleLp53H1suS
# DATA 0wNVYPOjO/4g7PX8s9XCsDclt398tlYAZNzZxr0bXBV2Y01dbml6+mvT3d1gLHqRAci8q1vvnjW08e0g7K3iDa+ku+flUqXFbPJv
# DATA ha8Laf3rDP8T4/CmSpECBACHnHwUofnjh6GQyldKVV0khLPiEoFWEMALYOoJ0CG/UM0ZYOJNAM83IXNZzyBBEgJkiyKk506IMWTp
# DATA 6muLzCnu4LA7x5L9yDgagEhLwdPS0/EkXzsHzYLAVQojB2AfqgFAcrEhb7jGogh+UkgCdDicOodTdxycuhSYi0Osc4h1OZg/87ks
# DATA nhUkO284wjplDK1knQyU3VYS0m13CmhcADPNw25TxBYD8M2G7VAVDf+O0Vg1WBWz0aYh6ZLUWhk4OnPfXvX8FagmEi264hIN13BT
# DATA vxC9rRDTYuYr2MARM9SDBhBUN9jGKTKK/oQB6qW4MbB8PdH52tU9B7BYYE0ptDlQbHnWk0znCWQrqnMAbHxqSgjjWvMQ8pG/qMvV
# DATA Ce6CRE1gvSCpzMOkqeYh9XG731B2EcPtxUi3SjXq9l8zhpSnDSkg1oHeR5CKyR8W1hPVQyHjWJS8X0BzZh5p702BW6zxx5S5UvLY
# DATA aUgoWqEHFgJUidQWEqzCsUVBxiUQ+kRyQ8YyzUqICjNRMb3KnCUYL+qRLSXipUeUVOfFYnpjEg0VtwHPlWjEaHJAPxtPh9DQSDkG
# DATA njPNtXbQseT/xL8t5AqwCtmegfM1PFCDqpWLv+8fxBaVKCCpPWLV3vWAA5m6bkzs6lumGBMR2yqH51Y4WdRsfj/e9quIOm0HytDn
# DATA OUd+g274JURQPMu216iAzAaVxAsUNlQG7aIqYWNryCPHUHJ+h0R4aJhtFKCcboDA0GnyJ+1gxIBymuuGCTr9eJUZU41Z7bQpp7qB
# DATA ZE4vOuCob5pkTZDBfvgAZ7HWcQaqM1CPY6A6c/TFMUfnmpnPOLCyvcGfpTDrJexUWTH092SPFRJsFWWhxo8wXo+iwnpW4ZefLzTR
# DATA owgdrFQOoZvjFJnzr5KATq9UfRwtkeTVKqeSvNRRM7/H3/LWS/aYmKz+doSwlLzxYNDW1VHoS+ffy5wy4wg+2TxzgLytZ/kLtytF
# DATA AqYTaTRW9uvKZtzTyNPcP9oYY4MtH7xZWWUaHpj5OqZDy5Y0HJyk7GGPanfB0HwlDcykOWoF+FL0Fem58Po0xMzP4m3LpMgwdh3J
# DATA 8DFQLy5QRUYBmS7+DlndiuAjtd5x+lWWgmYA3qudv9YXwm/qTcOGzMuNsXx9xYh8J+m1MAw4WN+HQTTs0Qr9gPc90Bex/8FoZopx
# DATA UWCSEzjhScNx4mPiaqI3Yy2mKaW5ymr0dHWV82eMfXgPejwVZ5p4GMiEEI+TaUngpShRpUZ7QcWujMiIbE8WV+wC7zd4Y1j8B7p6
# DATA 6qJ40myBez6mEvcRenJ/xKjZ0f6AXDb6KewDDl1P1tzaXBBnL1ubFxCk2PEmOyv+Ua349JRzcWYXZ35sA36uu3B6cWbDJ57m4zC0
# DATA as8kzdeT4F/WO7/0w8W7Q8nb4V1wMmWCaDrWsdYj+IzjYozcsy4ZAt/WUQTMlaUJjY3R/wGLQVQsSWCsb4g5lo2bkOYVVrvs+E0F
# DATA 7udzEKt9eHHz+OP8ezHqbLZx3H4BR3G2ZbyXblqHb0wxoQzz1bfC14+kmLaKSfaBvmjqWT9qWBrH4JnmXX9F+kdVlQvICaH1Sp2w
# DATA uNLmcYt2Wl+J+aaPqm5t2dpyIkcswPokGEh2pOqI7BybanzSSfKMy3dTuy1vTBaT3qaxq7oEJ/VFTZXMAmIU8J6Fjkw/vwTVZq9A
# DATA BHDPnw7IH8KGwHiS5Kg27e+AnIbNLt4jsFiGINlHYGYGhbRImZK3hct3QrJ37E0ytoSCu221m+HJfoQ66tBVrJlI8PCFwOZgjIQ1
# DATA 9jrYYxMjivcqlKE08kPF3gQuaX8okjo1nnEARUnHOIkk0bFWeMRQ8mR5keNhlz5K0THl8DDxDluaiIk5rTpRIPRRyvPzwBO1j0lG
# DATA ncGUoe2JovcxWuhonuwfmtdkEWZPx2EbUZ4wsiizZ//34aezLw9/D1br2TeHf5h9N7t/+JkH7mz64YvZw8PPsuzZ/zr7fvYt3fe7
# DATA 2XeHn9Hdsy/p4b/SvZ8c/qHg0afv6cm/zL4//A1YtFG0MGl/Qn8/nD1kHu2P6ZE/0y1g0v7Ko7vA1/0HKvYhFXsfT88+p2p9xU9S
# DATA EZ/T39+BlvvwY8eu/ew7hCTEon5QBLOcUGRp3imWVW1apiDC6/E2MO+WX1Eawtc2bUEowTg4RWbcsBcovjDFdkXSb6RJ7ZkbLDZa
# DATA F7JoX8VDJIMCR52d8Pdi8fCkybOtETk9xmw1q8aWp8cXeGKO03fvBH4srl+nLzwZdwLS9SdJlU3lMnd1qDWZSq3IOHUvKFf2EoN2
# DATA 4kzZF/Yi4NT7IDEnnTrQ9it1MIedFKMkSxMat0wOuMR8yWIhIXUn6J1DXfc4TYrsu7EdpfLHIg11cspx5t98CyZeTU+L+/rIyjva
# DATA a6fWH1Ota3rr42nzFyNy+wQ1+Ukq8qX0+LHU+BPR4jITTdPjbN+nulROg6DatFHSQ+c1j4W3ivjwOBckk5LasMtQGf5kT9rQRSLk
# DATA nmzZyu4zuee+MNOO9g4me/14wKxcSF/3hqIshipehpH6cuSZ6grxruZc5toMIk9WTT45b8nb4h8ZoHsszMSM6CxbWEqqoqDxJBqS
# DATA tbWnWHAn/g46TA7YifUQt8oQZFN/tcOx4FPoLm0jGOH4pR2/tOOXPkV+6aVUylL+ypKG75Ox3R/FdD8By90RSTsiaUck7YikHZG0
# DATA I5J2RNKOSNoRSTsiaUck7YikHZG0I5J2RNKOSNoRSTsiaUck7YikHZG0I5J2RNKOSNoRSTsiaUck7Yiknxki6Xq15jcaj0gk3a11
# DATA y93Gc0QkbXacl2KPtvsDIdZGY69Zrt6p1cpv0/e/S/dj0NjIobdqeZVWfa9Rb95pgd6qlXysXemsdyrpx/qVesOr0qO1crGy7lVr
# DATA 9MGrtYr1ulej/9Nv68WWV695IM+qFGstvlbF7Q2vtuHVKrgbl8vehldvFasV+62cCZnktqp1Gn6znMdtlTM3GqjP+p1KNU3QttPc
# DATA qey080qpZ8j4bJa0WpIyWMq1CLya8fStJZnMA7+xvpOpYbXafPwaViu1uIaN2gnXcGPjBGrYasY1XG+ebA1r69XHr2GNl8QpjXKd
# DATA Fslj17Beq57eKDcqrcevYaPcOL1RbmxUTqCG660THuXjEOmJEtJEeqLPLCK9jXqjUttIEumlafP4ip8m0ut2NoJGTKTX9BvBessQ
# DATA 6bXXdzrkoxsivQ2yjmutUyfS4/TP4iLrvlRL8dPdsx7KctElQkKVVtLr0Z3ANhZCttT3SHpcLVY7we5aouQUQ99bAen10C9I3dPB
# DATA 7xqHvmXLm8n50vv3qmR21pbdUytp853juTWr6SjG04lHCcvdBBZwxEDHwpEYVjzmFlA9LwDNcTirPBUFy9LzqdmUHA0MhhWVWMf2
# DATA Sn46VOYVJdSabFbLyycTVS8Ge4TJKm60N+aT7sUjXLDHZIEXkZ1tqrnWNFLB7sWDw64AZv1cNyoeqOP5o44E0JEAOhJARwLoSAAd
# DATA CaAjAXQkgI4E0JEAOhJARwL4gpEAYi4oR3GTrdOCj0OfBUD4jgoMw1Y+J/3Bp8M2ZbaEnf+2iR+LmC3nuBABj9hU6k19pbrdKBeq
# DATA hXqhSTIy7KYlpLptbU0/bu4+x68zE3F1UAjB/zbQYm9TPWFJvbVzg4W9BAI5rbHi+qn3iJa8u3n+rn6DSDK6ouzcu0qc0R+w19k+
# DATA xhBHx1bXPkr05Dk+BKxtRe7QtVSrBpvnqUF8/BLGKPvtWH58Dg5NKMnJT0XzR0WzVFIkeGtsziXd0Jsr6rwfBEU8KzdJ6zKErJwy
# DATA pvkoHHhX5dAxmjAkAcs0d6ZhE7Z4Qbn3Y/X2NbH888fmiJZMot3dXqIlhZDWOWaRNIkLvYHvt8wQKELFaJNnpbb9x23gPKK5a4Xd
# DATA xE9vkRNBEzsilRVQxwzaBzJo/Bp6W/m1Sqt8tlYrn9st7dK9MBZ/gRu22KhfxamFgipQ0tBxeU3fHdwdRgMAtvm9q35/eD1KPluu
# DATA ZJ99pVRuokLUkAEN0eouCtNf5G4g6YUD3tnEnRyBWpVP0XA1r8R1GiYZwCvSmQyYCHLHVXx4pcKcjVHXa/GQcuP1Lz9rneO5uGk5
# DATA MhjpQq2MHTghgEQYJeK5dk/5JIyMrykY9XT4KJ7759TUuKfXALvAE6Qb8RBuXdjcDwfkWJX4VDnPy7uTX/9aXdwPdm6HE/snkRYX
# DATA 1iZ7pKe9i6MRz245km7pabSPu0jmwa9/DX9w6wJVyN/3Q/L+uPsgp/vQkzmT+ZirKBpai0jkoyyUc/fY27f7RMZI6pw0L7LH1wX0
# DATA SBB4AH0op7h3Ai8gN02vTZI7xpXNEXV8Pi7skVuXEHoYMvOYqLw1q5ZUqBqFnCKxx0+PmKKs57hrX5NVL8VITM0cqnVYNg7LJg/L
# DATA JnnQ2oHaOFCbZUFt5gKQnxbYzUXsu7B2BdrEILBhWzTwzdMDUHsSKONiCtDl6/jgrWI4xmf64WA6CY7CsdbPGuFkLhjIZYUanoaE
# DATA ltwQhQldXQRhrY/5UrX5uC4Q4w8gsri/IwbOoNHhDbQ92Wni4aQC5P5kx5j9JKsnzI9slvKWtfQNu0BlvjPZETqCE3eFuTVuOj9Y
# DATA SaFbL35XZfl3VZLdjAerx3pXdfl3VRPv4gdrx3pXbfl31RLv4gfrx3pXffl31TNQ6+cbx3pXY/l3NRLv4gebx3pXc/l3NRPv4gfX
# DATA j/Wu9eXftZ7Bfz/fMu/S+CpmDc9FV7fd1x8AmLpWFULpopGILG1Dsu+2UCvh6Ay5ciLAREPCewBtMjvpfUAtjRIiT0qoFLxawWuw
# DATA OloHi1YwYCBVDxkEXLQQCvcNE5hVMVJU+fFTD/KVyQws2C8TbY9RpUhNwW/QiGBQgihTrMbj44EtAWX+/IMJOdJW5zotdp2cp/TD
# DATA 9JSOS8T61GFBObkrzvM6DQpPC37zhHk7bfDSXLLOuXSyjCHIJw/NShVeFMCML6CVfQbAUZ8TsMAl4c29OHNQG1cStdT+spzYod4h
# DATA ZxoomkBJMobWlkJo9UcMcoXAKBlDeJrMKrKvmP+U914ErHUobjyndgGHEX46ZzUV8IAaqBi5kR16GqSwR++4g0xEYQXaBTcZw0/S
# DATA y5kjB7h8Ggz9+L0Is48xI1PYsU8SMv3pWEqJaemMJWcs5RlLCVHlwswvfJh5rpH19DHV9cyn6ewzrPQBIgADuo+TkWKM9eEISxMw
# DATA wKlFtjsl/5hDzaNAYWBn4L1puRgEcAsZPFIuPs+hVGA5YTVkQdTNfaRX9TJmjUSja/CVoTajbtfz70Rhh3c/B1E45pD4SGNqiziI
# DATA icfjhmlEt5J3jVS016XSBER9zPukcpQYyrcndRlz/iIKOTBY4CRZpjtjWvTTiRhuDCMHzu+OZoRDjUveuwpn2+uH7VE03OMAjKKP
# DATA C/w2h+XxPPUAcKshvvIj8XG4x2dbY6DQ4HWnXAsmYkaMY+jnXoRElgnYfCUBb+gzqaEl9jSBXsnbQmdS0eFwqIi3UQSH5M552NjG
# DATA Vabe9uUue8w9nJGALB6gdzT1u7SbW+Xt09t4Z3xB8y77sGuEt3g3MqjzuMrmFo0EzGIZYE07T6Muk3wS9aPRKNpX+N4y/XmXXA8N
# DATA T31POnGAvM5o2gYGDNOgS+wqPsQbt0043A1pOg0VFJ9iWV7UnjcZnp8jY9jgyRDk9MiiYxckgLUoFqhChI+gpCaswvbIZLANS1qT
# DATA cBrY1BuLaUi3d3FCHUvB6EGZDqBDFJoAvOh2wOTzmHnUjX0ZJGaeJstyF1O5ByZ6qsx0AMWMPaVoOE43Uuypo5iCXpd5zjtXqI/0
# DATA qPTCNB0RRrVZ2SQSaS2pW9SBY6i5uVHlRUHk5EaJGYUFnRfHlfmVj/nairyWfpFlZRbfyb6Gt0tk0cRcWMJZwIvoZN/GGyZXeWTN
# DATA ZJ1A6FhCGCvlZN/KWyfI+56/MJMvPDPtPWYs/ofr/cQUl/S2ThSNxja/5Z9m3x/+FoSUh79n3slPmOHy48PPZv8BRsnZw9mDLMHl
# DATA n5jBEvSUH3uzr/EPk1l+PXt4+FuPqS8/Pvwd/fepMFyqgulFTGv5HRX+YPatZq9kYky67WuwXD44/Cf67StHYfns+23XxNMaRTCS
# DATA 2BTGplE03d2bMEeOwEwr9doLJ0DXkFPExhGbDrTtQqYUtJ7P5K2i8NmCGYvnBhoUmIU+n0FdyF95jTMuSBaGPe9XZDGyEeWYLGMf
# DATA TkuBJ01jmTswp0doyfNybPmPepoK5VHyZkxWc+sVNXOh3k6SzZKMVQZSUHuYkmtCS2LomCyXGK0TJ7LcUqlVPVoeB8V9v3c7Zmoi
# DATA sxp8O6D/Uc2Crdv2cdyItOwI8GyKXsfvQEMY0qhBEJCRjw14mpcH7BsoFiScnx9mmCyPmHnzzZK85fS0GC2PaITjs3Q6/nF0vCaz
# DATA fFTV/kKEZp+YWj8drb6UUj+OTn8CKl3mZU4PGIX+FNfPaTBc5jTVIz+UPjH3nK+2SaW5qGWB9zl9dHvYhp5Fi7m5eVXmxGf18CgS
# DATA okCRTTvYN+f6+ly3QYJqbxlyy0SgG1VSzTDYnxzuRqqft08+NvaABflgLKyA3vvj2IQSzU+WG7K8u1SzEIaAUBOGA95bMmyXsHZC
# DATA eYGKDGPQeCNry6KGVLHVTkA6sh+S2bC/F3AtfI9NE06w6waO7dKxXTq2y1Nku1xGxSzl0ixlEz9p8/5RrPvHNu4d5aWjvHSUl47y
# DATA 0lFeOspLR3npKC8d5aWjvHSUl47y0lFeOspLR3npKC8d5aWjvHSUl47y0lFeOspLR3npKC8d5aWjvHSUl47y8pmhvKzW636j+aiU
# DATA l61gY6f7HFFe5uw8H5f8sl716s2mR/3mVWrlXqXc8Crr5Uv19Za33upVW1Wv1krxWtK9O1k6zH5lo+ZVqaMblWKL/t7wNprFeqNY
# DATA qRSrVH7j796tV6jsVqPXrBUr5XWvte5VquvFBt1SL9bo9RvFaqNYW0+NSSNY3+lk+QFrVO31DyuNcrFR9qqtilee1Gstr3xnvfV2
# DATA vZYso9luddar2TJada9RL39YrJbXiy2qVLVerFBfUI0aqGmxtX4Es6apXIZHr9KS17XDEbylNg9/kyvhtXloKzJzR0JUmKhvp9Gq
# DATA 1+uPwJbH81ez5clSsNjydpqNoFZZgi2v2QkSbHnBeqexsROz5TW6TdjWhi2vtlNvVWO2vNZ6vVIJTp0tj6d9cbFhwNH9VGyahgpn
# DATA L+9ZBWjbIMGdJo3O0rmpfs3G//AfrfBzR+0h5Bs788jfrFoezcJnk+zJg8cj2atnSfbiYo5BsqcDkHP7yO5p1aGKxk7NPztiVGU7
# DATA jY0Bo8TmpBFo3a02uMrzue/ifi3YXbXAnDiiJwyjnSOfc+RzjnzOkc858jlHPufI5xz5nCOfc+RzjnzOkc+9QORz3DacRihqm4fa
# DATA +NoihcYURNJDDDeUK089wz4GadDbPL/ay/A7qRavaUH2GhVz95a4NTc8fFh7pZecZDzz10q/isIBFXCT/oAf6pwxL2+u6GPncV1K
# DATA k7vo15srb2ROpKsCXsFnzRR1wWQo6FI18ZPmVnII4e5g9YKD1e5A9QtyoPq4eOFP96A1xyXjUFqWjqiXwMLcjaIOzhZ7HCc0x2yZ
# DATA SQKFLMDZftrns5+HM4r89wljtecdJD9p1Pb8c/m5+O1LHJOP47QGPzwQgDqMtoadVJPDYMxcD6gK46gfAAiGj9bKVOMT8Cr8xows
# DATA ghuYPF8enxwvAAaZbM14sbPPCDxTRICjbheBaX2gWXAPUbhMNX5F+vD5cUDEM9NEDuT6sXXydMBqnsZpVvO8M6icQZWDRhdPKAdY
# DATA 4wBrHtWOmmuvnQ6QDct0vQzIkhLsCsbA2Ism0e7IH+5ZoOJPDTftBAgsSS+/oWBoLO11TMxiMQZQyAkCFivdr5V53x9y51g6Pw/5
# DATA 9kRQiz9geG+RjTQbgZACyXcKwMVvwlbnFw284C71ozcenDh8MIMWvzMYT3v+RNDLD1Tz9tHQIQnxrkfyrtc7DdjiKWMqTTTvzJQx
# DATA wFOr4WTf2xDkaUB8dzwBodd6jtTfyb6L2R+vBKMxQzFhp4r57QUWhrmNin5IBvx0SAsyOGE06vVYiKYsaBpOH3ywwgEiBvcJQ0Sn
# DATA uCZjt0yKTAYm6SGNFeT1D4z5IdLG0FHGBJA2orrZDooR5eEc2PNHLaGDGH1KFJqcOBrPgZZqg2BR40pZuFRABWJwKe8aAL6DgcfE
# DATA K4M2DZSGn+oq1gPq+4JByIqUdNaQpth4OtBYSewRjaY7OwDJ53FhTmJMk6jH9MWiBwTjaDQFkJenO83geKnwZiAvMJvdvsJNXY7q
# DATA 8YfjflgGhXNAnAOScUCSFqZzQZwLknRB5joWTxtLU/F1MKfFnj9ksmEfHoYNjj0OFO6ehoJMgUUy1Y5Gh1TUR4E4MxbO48QGgISu
# DATA 7O2DP2kqdCFpiEdZsVNayiS7aBTuBDlIj8uibXJrh+ff5K3NuN47B7F3xLzLO9Ow1zFYfKoyHGjMho3V4VGLgF5Tb8tuPxNW4ZOy
# DATA sJQFpH+MybPNFUYR2GOuGJZssjkr2Sukuq2mJEnA1XtNCgGsUvX5VUmMUC+37jCS1X7q1YglbGz4YQ8eOpaWjbqPbctIBXLTt5OD
# DATA qg4zvMWf5t/Z7oX9Ha4oPsy/jwRzhKQsuvOifIzvPSNtO5+iKde2puzG26YmNMoCQzMxukgGlmWvzkjHlrM/6hj3lJMfxFFV/Zjs
# DATA hxQxF2dSG3EgmQXi2E759rp3u2+aka636VQgR9bOXw2Zq6kTMJkQrdaaRAn60XjSO1Dkl/gJVqKBYue9GuHrCgcTUYGBwGEiS3K8
# DATA Fyk8UV9IzzV4LBOKDwzULK1cdot1eFtBYXqwzJR1qA5qPdkObB6jAz8gn7jHsftw1CZ3Me5C+KgkGEDFZQs65eUgUkJi4VcqRYck
# DATA 2QXeJWDbmHMrYbb3ox08QtIvkDlNQ3F7LJtmigWMx+IkustaJcfsr42F/WWWnHTYe4D8pHWxG5iuQjSB70n2kaHgko4seR+Qzix4
# DATA jJIXkhF2oOJPikSMxLmwxEm2ioTDNM88qQ2mcQs6J9FVRvAcs6PWF3aUkmLSTW8jjiPmfDiwZhW/mibEPtVyzIEYf9RTu6c6NoMg
# DATA AtLgfGDVyk4Xu9n4GdG/3YM4XhhgCxA5+cKcC8Ixlnm8DgGpy9QVfNNTXZONY6zJSyCig0yjdVekRheF5MrMNvsyLTdhrVMdae28
# DATA Bf74AJt7mhGOHiGbX6CHuT/FFhmDxsvyyJ/mBKtUl59hlyIaYtKRveCAwwTxHOvRL7GFo6K7EvAj75aWIEfiYmMNHUISngNWehNV
# DATA bYqKtQV0YJzIidQcJWtFQlBgIxyF7dx+Sypiya2zFbG5It1w/nKks+A08jSbYCo7DUERNZKKJVr3d+koDrEfSgAi5hIbBhNQ89pU
# DATA Yv9TiMS82Zez+x7TeoH969vDf5jdn307e5ilEfv/Zg9mXxdn34AA7PA3ICD7K+jCDj+h61/MvqO/P6e/v5/9Zfa9d/iplI6iH4J0
# DATA 7P7sm8M/zL4+/JT+/QxvAhcZvZnKuE8l3NfEZN/O7js2seeABXogOz/I42krlPqYBXoYREPmb2SCdVbttPbEQOxEQD7naCMUjRWS
# DATA VmC4fBdkdAyszm8gCRIKhDwHjxeyir0Fc4m52wcHjk7MjqEoQfCk2cSSA3K6NGLhwNrDvahnqf4lyyU2mOAQoJGx+CqaLhidJJ+Y
# DATA PxGKgj1/TOoUFixZulG36+jElh21E+cUu+D32th1DGQD7CAmqPb7nGnPWyA93ifxunAlPOaFY7g/s8sBJt1+P2DnF7qE9xHDvwuY
# DATA fcPrhMEkh0bsyEk33zpJrKWnxyF2ZAscj5jT7ieh3TWf2LGV+guxKfKkFPoJ6/OlN0OOpc2fkDKXGWn3QZxu9fSXzmlQidltlcCw
# DATA yuDYi+g5bD4kG4oWmFrqwcIm0YKmvwMO9t5wLKxK3LSJP76tclVQgXCAk2M4xqe6ZDkqMRAYiaq+A74uRdbUiZmdZNqIWm9rmwDk
# DATA UxES7WATYG8rJAMhxy6YAnchnOTZA8oaYOIj2AHYvRrfpsJMPUIEx3k20fzqIUsbOWTTySiUMYsG7WA0GDseMccj5njETplHbClN
# DATA s+QJjCWN4ydm5D9a7PEETHzHJubYxBybmGMTc2xijk3MsYk5NjHHJubYxBybmGMTc2xijk3MsYk5NjHHJubYxBybmGMTc2xijk3M
# DATA sYk5NjHHJubYxBybmGMTe3bYxNqNapbpalk2sW63HrSeIzYxe9v5uDRilUbNq22sf1islYsV6p/1WrHSaPaKddBqVT6sVGrFhlep
# DATA V71KueqtV4vrHu7CHZUWaMCSXdfpbmysdzMMYyD4qpc3vCq9o77u1TeKG3Sh6rWaKLLhNUDj5VVQ9gZeV9tIFttotjqtbg4xV61s
# DATA EXNVNxqGmKtSTs6Hnfp6PcgpoFG3CqhZzF6t7JSo5zGDVdeP+7zVL7Xaulejfqg2vFaR/qpU+tV6hfrIQ+eWuYvnN8QeRbqz3mjs
# DATA NdZbKaYz80CG6az5CDxlvDIMTxkvMounjObR+rq/BE+Z360leMq61c56u2nxlG00u+sxT1mn1a7v1GOesmqrWWuunzpP2TCYHMlS
# DATA Bv2i71uC5ssKlNU4TFZq8fYYVNpalgnMlKxpzhKebr3xM69B/1UbHHRMUHNJj0oJqsLLBdVUq0xgrWrc3dTbq3WOBXIYL2XbSORp
# DATA AYWXblchUb8FKjxxmw6BOcouR9nlKLscZZej7HKUXY6yy1F2OcouR9nlKLscZdcLRtmlLA6Lh6vjH4w33/Une6VuLyLHBmbfzRUc
# DATA xqLWvwyT5oy6xuejcFG+kpsFQ5VWDVufN1e2huTg3UWIMugdUG+8gqJfoV7pTgUujI+HdS2cK3XWineRwJQFSi19mMtXh7OAQYYi
# DATA 5diNz4e0cUDFnMESvD/HsuWOHR/32LE7bvxDPW78KPRaz8AxZA7f6XjXYpYtAbAy9c49qpzDr/WsHF5+rs7wnQbhVvK49QkzbaUm
# DATA w6NSbFmB1PgQuerpmBYE8IwCIK9QV7i79mrn32QHn3HlNA4dTx8AhQ4U3pwchDXTZ9+nJ3aifZx2DnanPcD3adi5PuBEoy7Q8DvT
# DATA EU9Qf9TX0PfqTDy/W1dgi2zrkIxfTpvVVdAsYdQ9XWyS7jAW5wRxIo+TU8QywVZrj9sGPDteCzhRuRPgxR2yyaajHQM8+YIc9bTK
# DATA cHaVs6sWgLXZk8vhujhcl+MaVAvotk4H7+Xng2gf4l8QB3b8XcFYA+SGUmyVJw8ndgLsWrwDoTJA9LUENjw7+nT1/QHwFgIFw2LC
# DATA Yt7q7d21FBPQgPeBYqIdVYQRU/p7gg6JGk0iGXgy/ZDhbcslyGySLJKSI8YRcjnjH+fA2UscAoQ+NmDLECmupOxXj6yvfj6Wq/pC
# DATA TMLVKufV2a4x0nXsKi+oMEdKmKUJ4eoYxwYddURd1aOmqvp7gi5sYT0rC2qZYlBS+0tYrSroImjkPNUtliRMqvOvSq6pqqfaY7Sx
# DATA fONLIl3CO9IC0r+Ks/WMFPF4LFAWZ5O1vm3gI4VPryhefCx7gw94EaEnewHzgmaslOBuKCgurO4gcXQI6sMpSSFglY+nu7sBR6BB
# DATA GME7E0pARCPQWIBUiVGloYW50AEIKnqajUs40Dg2rtYdAFTIlJ9yPJ6GBngwQAj2dw1HLBCoYJyORZN3wi5Dp0wEf4iRnT2VyhuY
# DATA +ggcPaCJuBo56EQxJBHDKiPSiMp4/pDmHBTcstxOPxBjN6HBnLnrzN255m7GtHEWr7N455uwzwjC4QVG3wNmcRdKJhwwjFk+v5Pm
# DATA l42hAEdBP2SKjsI81L03hVMwo24Y2Gx3GnZAZxgrRiqN1mtnCgJCVm9pEzhJmpABODT3kV43nKY69sSq/n3mCYA+G0WkOvyJ1rls
# DATA h/dpgU9hQik7wN8dBZq+MqsyFf4hldQhVW2ag1BVRnEyNCDAZThyFDAmnOdPMKGpwuds1nbNDBnc5fQovCMEqQH1+hyPQCDeojuc
# DATA 36Q4ODV/7lBzeCGRU4hC7gajdoh8xwQJqnQ4DwyD9llAhSpKVvLeAs8Wi1GOpjFp1x5sLr6LCUzAWIlw3aVgwnKWmwHTxp+k4m04
# DATA uGYq6/HhBnCfLGrjloajNPJeN/IDeG2ae0fJfqBMFgRzTxMT4RHsP9JA98YFZscYG9ZObXSJmXQZhUFSHsAEU4mWrFlGrJJ2YGkH
# DATA nbDtywgq+kx0ZWamWzRnwV3Seb2DRa28zEeKjfnF9CW6nVuc6akOiUxHBUSSGWG8r4ef3UfFlBOC/ESZrwMg8SnwT4sjjZuURKos
# DATA edeC4DazhCAsy3we6Eu+VU0LjViZ4Jfh+KnwhgBtEQFiHSj2x+zU+ruDaByOM8wcbIgdhfN9PSLBxP0ZiyBeNcdmiuaYttZBJ8IT
# DATA bYW51WJAeJuD2KfADP0upq/Og6Hl6mPqCv67dlNOgSX6QiJYjjVL4y3ssqfAFH0pnLBXNiKxBSBIIYVUnDUsOQVg8hTIoq/05J0Q
# DATA kNzaeHGxm9U5BaLoLRJAesVDSnUMvi4PKaJFo84Jcyf/0P03ixeHnpqMbVqcfwMJzuy72f3D38y+O/z97IF3+DEoaujrA7r88PCz
# DATA LDPOn5jq5s9MapO8e/YVs+R49NMns89nDw7/SZXyR/Di0LXvD3+LJ+hVn9Ev39ILv/IO/zHBtGOR6ThqnOeAWZiJ2Qx2rXBkIfIL
# DATA So+CpKEKL3CXxdY+SLn3lUW1GzBi8G0EnIVOeKK5EplklJUoOAR3e4sZcC4Ffpff4uhvEj4mr/cnzX5jDcbpUd9I02KxyHOny35Y
# DATA +lZoDnMju3qjvYPJXv8k6W44yZbcnj3M+A57BKDc41RM3O5ob44csRPnu4GTG+3Ax+R5piPWyBRR7jDLl54/6qutqdj5DMcSis7k
# DATA UAt+Otu24kvQaJEUg1tHpgsC3Bn6m8Xzb77xEa+jp0V7s7jmjvHGKe1jKG1NbHM8Xf1ixIKfjJ4+STW9lJZeXkmfvo6W6WcabRTy
# DATA k1sLp8FUY9ojDMnjdEN0/kWcxMD2xF7U12Qw1piIp0sKDcrO73BDmQXdMFKMFcdyO5qOhJsi1q+64XKUnV6CvuLil+OtUS5+Qgf7
# DATA JriutbfR22O6sTPtBTolkrewEFX0xsOgHQbjgql/zF2sAq29UEKvAQlbvxtMDhKhQNUOptNlmmimAm5Lo5INcgQ1jqDGEdScPEHN
# DATA 0YpjKZ9jGfv1ydjfj2J+P6717choHBmNI6NxZDSOjMaR0TgyGkdG48hoHBmNI6NxZDSOjMaR0TgyGkdG48hoHBmNI6NxZDSOjMaR
# DATA 0TgyGkdG48hoHBmNI6NxZDTPDhlNrR7UOo9KRlPpNp4rMhqz3XxcJppateXV6uU9pp+p1r1KvfZ2rVFNdke72yo3svwndWpArb7+
# DATA i0q1luY/qTfa9VYe/wmPUrKY2saGV61X/3Nlo+pVq2X6b93bqHxYabS8lldZr3qVRoXeVfOqG7UPq5VmsVKjMQRjTr1YadItRfpG
# DATA N9Xppgo9UP/P1Q16tOrVqIRa68MKosh1r0731JqJdtWD1kaznCWIkQoVyYQvViqtfqVO/YIXNcug50m1tb3R2fDbeW1V1DM0iiGZ
# DATA H4q7pl5uxNw19Y2yNYHr8uUgZzZ32kGz3X0E7hieyIY7hteExR1Tr677jdqR3DE73U63meCOofq02jsWd0ytucEFCXcMCYkNP7C4
# DATA YxqNnVr91LljerQKjiSPQdDoXnyrYXmxeFxU67KBPQ7uVenf1s9sc3udzYe4yKMpaWy+GU62k9zivFqY0FUpZ/+ULCwPW5VeU/5L
# DATA lOYpi8YQyrAWNdI/wVwjQ5xqMZUJy8hryH8mNCrNbsG4suM5FWuPRxWxTh1Wof/Uv9rCZOuVFeJctpolxjLZdUkfO7cj5hbkSG0c
# DATA qY0jtXGkNo7UxpHaOFIbR2rjSG0cqY0jtXGkNi8YqY02CDW0z8raa4u0GZPfaKnPpy7UYwXIwFzR6qmWWZNq83yopdcmm8Rr57DO
# DATA b65ciNG8cFjFgnMZUA8rTBe4r0nOGnPywZ0bdueGrZMv7vSwOz181OnhuViTp3Kq+HXMXCDNxYWbk8VPFX/iBPDSgTWHN+8HwW0+
# DATA 4Shr9hGx5mLdcnJoc0HQU6jcO7JLQh2i0QdVoPsUYOf0eWNF3DakUe2MgD3nkY8U9A5OAXPunQEONU9Ewo4VUjbs5W4MUH0K4HPX
# DATA OfSl2kgmiJLmNCdIdxSBft05Bdy5q3KUGDFAMuVUkw25wKmMK2PPXcZZa98A0GHliYaDyULmJXKhpqPghNHnVATGQMfHmIwJZID4
# DATA cKtuiDk1Sx0GETBJSBALoj4GhRcIeECopg7rszQqxeiandGB7uiYqsHv7YO3sB8whDxuwUYVGRq9Xsm7FHbNciiA7qGXXYsKRXWA
# DATA qoy8PfpxFGDDqncgT7J42ffHUh3NKKTQankOCso7FhuiuYJdTU4FttjvqAJodVA1Zb7sITY4UifigZNJj3ZJpcyDDNC9oo/7k5gc
# DATA 4OQ7pxmQPmEoANLUaYiflKa6GuA4oDrFLU6r3CF652jY+Of85LGjnHT2e2y/O4v9B2exH5dS8iniAPFmvtmIXswj+WbI8OeKHAWg
# DATA 5wOPc3kXkEg+YfigZx5O4zT4IWOQo5Mmh7ThoB6VGdJKUtBu01UcqzLTQRw/Bk5RwFPV1EAiq0FGUWU3grHx9ZE8DDYApNBp0sYt
# DATA rzfth4NoSi6isYkGNMkjgNgMg14P0O7QoXsKcZ3sr0HJe29H4PbJMEHSNbCU9sgkVTQHzGej325X4y0YaHwXN0bX4jLsIiqCakeT
# DATA l2aNZXaxycfnRwJOQzgYA0vdHzOEuqwQjfHcB4T1aNH7OQztJd79lqygMZmXY96KLnnvRuOJtv8EXIi5f3Stz6GDZH2BewnINySv
# DATA YRsA2J7ECE11hg1J1+SHDhJjSQZnqzlbzdYMLtj64gZb53NOPk0Ix3d5s1LPZwXAxkevLVJKQOsxOcIdYLfJ+omDNwUOIzDBJAfR
# DATA dOCw5F2JwQBxCkdQ2gy1D48hBw18Cz+QY5ocO+iGbW9M7n7bRFZ2OJUsxgwUzMUlMSC5xRL4iBe/7PWhJgN/NNJ8Qny4BO9B1CfH
# DATA SFRnHLNsl2qfG5OUP6k4mYpk6R9jQkRzhXsctCMBlyNPq/BT1OtZLchlgDSb5zxN5POrkhKgXm7dYQSl/dSrEQvMOHyH3WdozF5P
# DATA b42GiIdGyppL3052A6+qaH/+Pbts9jBlFn+af+cO22mMkT0SK0XfeUZaFfeD6GMdLZQdaDvOB9WwIFS40Ga0Ip/+qGOC8LzhL+F4
# DATA 1YNWD6SIpDgz2Kx+2UrnKTSack9smQakayx9OWSD7QJAHMMRgEwx72OzFfZaUWFyFgRitAjPTGOQkhrrR52A4/gT2LMw/LQFJ1RK
# DATA djARAUgD1Rkw0JA2sife35HCLdnx1SVjqZ5Jk2NLI9kU0zUawgwEr9ju5kVEz1hB17Qte6zhiSffMUfo2vwR0tNYBunakGOwyRGi
# DATA ZcyCRCLuoH0BVuYe2T8SBvU9mevK6re4A80eCJ6XXRCBWo2APgqXA6OLDEZlpTz+2NgtePYH5sqyA3PFH/UYVNbv9fXAXIu6TMY6
# DATA IK3GmKn7cPJIg+4mfbOSt3UnCuEZU9+bsH7BDn3zqAxJvsA56ygvEe7hY4+HXfEnNh6x7D3mePzt/PHQUlzG42/JYMkIsmm7Pe0x
# DATA miw2AdVJQrU4tLOquPRISvFOAs5jk8ooeW/T6joo0BCSGRKFPUE57rMUi/p9gX8m46IvXGL0U4geNPvFjz9QcYue/WG6uuwwXZ3u
# DATA 7KTl2esMYq2kWTD4VXQQSzANxlXyPgjJ3e1MSdDvylaUgU/Wu0KxhQdObeqrtj8VdrzHHgu72s++EHtzWSH2ejjqcMbAAAEgWhwD
# DATA a/HsCeL13rQfdorYKGSIcTUerHXGbNgDWmgCy/wDX/NSx/v8Nt8eRthIOyqJjCeVNgEsZISHHnucsg16pNFK2n+Sxmjbf+aK9P35
# DATA y5FOONQY3GLyi8XNW/9MaumTx4Lu0KOsNk5PhxPtuY54xVxo470oSFCh/Y/Znw8/nX1++AdwlYHGjD5/Mnsw+2L2Hf39OdOjfeUx
# DATA 2dnD2TeHf8gSo/0b06jdn31Dz/7Fo7+4wNnDApU4+5K+MfUZ/e/72QPzEptJjW76dvYAnxSP2hdgRcP75b3fz/56+HvHivYckHKb
# DATA NAdOeY0m+5p21TBzA7xYmFcL7BlxmlUAE09zAYA0FOEEhpEhASDkDBCgQ7AbKEZXmsejCeeM4bmubGGZoAAiHQuZ04Asj6Ugdr6j
# DATA T7NjfSwinjR7WnpATo9CjbSF34t2Y4ovzjDkl6d5uM90w1hMvxlOLPqOk+NQgymtzm1ghkaiwbkbHH3a0aN14vxp7woNuLdDxgUy
# DATA usjv3yO9Y9zLgjayxhEOQ6EjYciimRB3KqcV/o1iGr8LlJQgFk6M81Ugm0q2I0cBRxaZYVYfE+jTEAm9BpTVJMOttnhezjdiUqvs
# DATA aRGsLa6+I1hz+v+E9b8mYXsEtf9CbO89GZV/4hp/KYV/DH1/+upeJmKy6UbLP1vL5zR425INZyXJHWJIx0yrdw5QUkHOMI6m8iqp
# DATA 60QIncZ9HxtfZuvNE7m0E4wR0gpG2JrkRpOijo8tqOp1wq7hdqNmH3iKyWRJzraRMtc4rQZHVsig4LhE0L4N3aSoyXiOCe8Vnxrm
# DATA TCBhmwvHnEM1nggbF2/NBuOJmArol9hyOKdYzMCeNZlSCX1/MO3i88g2ElTkFXECtmlGB8Vo4CjbHGWbo2w7Rcq2JbTLUo7OMibx
# DATA E7TrH8Wsf1yr3hG3OeI2R9zmiNsccZsjbnPEbY64zRG3OeI2R9zmiNsccZsjbnPEbY64zRG3OeI2R9zmiNsccZsjbnPEbY64zRG3
# DATA OeI2R9zmiNueGeK2SqPWrpUflbit0W0G3eeIuC2553xc9jayVb1avfVhs1GsNb1WrVipVXv0T7XqtRpepUy/1LxKlT41i9Var7nh
# DATA NZreRtmrrn9Yq9NVr9bw6tW3K5WND4utYm3dq1aKjVSXBhvdamcnRXpWWa83a/U80rON7MhVy1693NhrrFfv1Jpv09fkC0xZSRa2
# DATA KrWg2mx465VipdUv1te9estbLxcr6/Sl7tWbXrNFX5auWKWWqVmjApK49Q+LNRrUIvqi+S4VgNr2anQhwRbHmZzJlwXd9eYcmjs1
# DATA gdvhiE/Y3ZVJX42p3yrrTCTHqAbN5AowxVIBMGw8ebqMrvXk4VYrOe27Xf6u5S/DoTL4a61F84bKOCZtHC8jTRsnK9KijQsarXqj
# DATA kaSNo5vq1WaCNi5FJCe0cRudjZg2rt5uNhrrMW1cp93e6ca0cRud2kY5OHXaOKy/o2njatooEJNAPzOHPw7NTMUXGz/z6vRfjf5r
# DATA Nn5mF5Hii3unT67EpIBUYNTXu8yIHfTVrrntJjXK5XPpYJ6EewqtO/sF3iWbsyOmqgHyquFHy24VlOpWX3i1UbIYT+dTJAwS4y8h
# DATA q1qH+HSUM8lppzqpSv9VGtrk51hROCELq50gstMxbJLL1Qz9XHk+v5zp/YLdAwtMkSMayFaC45FzPHKOR87xyDkeOccj53jkHI+c
# DATA 45FzPHKOR87xyL1gPHLK4kgKgHBA5W/C3ru5ImuOGv6KfAciDHcDm5g3V677I6DQ8iOe3Izl9QpfoGnxJpLpVitrr1BvtPulm/Rn
# DATA sGWdEr/4fvIYHj/8rj/ZK7GHvsrlvFwpNVBCfLwv59B4jHwLKC4j9jXVXHxsxR2idoeolzlEbR9tcmep3VnqBXjJT/eMtRwNLuiz
# DATA vjknra+ac4EyRwpJZDVzqFcOrCpAFj5LDDt6X+Ewy0negFH248OTQ/8AzrQcngTWysA6Obk0BvKbgnq8IxxRHTBQ4dW+EegQBA73
# DATA eBnc47Y/nvoKNg2f5t8JkUpdi1s/kI/z7yUB24ki7uj35OPzgIAc98UxQRAvzAdB1L0qIIhklI0OOsAh8gd3/HGMgIiTk7S8gCDe
# DATA jjhsMh0Oce4ZiQY4jOaNBBZyDHoOOczOUTBaakHJo1Ud4uhwCkeH9WFndFDwAn98wAvl8XEPU214YhCV1vw7OcRQM5MVTjVsh9EU
# DATA ZmQ8Nu3peI9mbsAguTiDLkeofYGrZjMnNiJgVcIuERoGDNQeeO8gImJkaoXnwMfDp5gfiJfuaM6Tx0KnjhvwHAzMB0sPzFWa6kWE
# DATA VQ6AAW4hh/LB5gKNyDDg1cPLRi8QJpLBwJE8wsLRuKE4RwjEKiCGB0O2DdHhFpqGAA5gb0v0W9jbi6YMPfr4+K6JpjyxUXpk4XZp
# DATA WeH2bojMGWB4TEcWMjI5KOTzIStwEg310umGoz7ASadDTw1MNGIINv5V0Ev2qVGjaEfE3SjAV8YNmw72yKgCuoEN4/E4Q5Ko+RMb
# DATA EUtJHnNIrs8fEqNuZUyuj/ywJ3gpPpk1ZlDo+wTGCey3SHq4Q24PjDxMTcOGOfLVclCY1SAT1kgzMZJEDPYmICy9A0F7e+yBSVb/
# DATA 2V8r15ZdKx+IT0oOajikKWwGBrMbljO57pIiBMOa1Ti7o0D1GI5Z38PNBx8tEnMVZdZYMMMVSPiEQa0xuoicPvZQpGr84mId/xDg
# DATA RPTjLrrlolvLRLfsKeaiWy66tXQUa24Q7HSiWwy8ZQjwfG83igQUT8e2nln82kWxLxxp8OwIWCaoJeymSBhRecj6WiLapLZnmJpp
# DATA gPx7dlTVRulqu7+mwl56YYpTilGUUs3zRpTFV0zop8rZtSNIbkixfsgGUpXTqvs+p7zqRN5gyKnXpcr8ABnvIGGWR2pchwa1LBkn
# DATA UzeamukHM6GpimLohd3TOetVvHZ/fhyrUmpwAIEKC4MR3V1qJO7PxLKUhWUChZJ0Q0Vc1PCFKSlrmUkYP6oCHy7SrZLsK9t0iS/J
# DATA Eg/FPBuSPpxIQvoZKeIxDSAxUqCMrPVmo1leH0n4VRhjIQcyKNE9xmsc6ChtQTwGtuE4KuLv+qFkXSElXmikyHsoeYbkLp6nJY8H
# DATA rcDKzyJkYfDKuEjgVY61dYzXwZoahgOhsUKZZBEbCEJsKDKCGg6NAdJx50CWpwDz+UCgtHcRx9Nd8NdypkC8h6nc1oGGoGS8yhh2
# DATA csoW6oFn0gV0TtyQbRhNL4uu/sEbnrGqcaanMz2XMT2drfnDtTXnWofPIFo1n+gwpwuyZljPMkPfgtnJtQIL+SiQbcKxtkLjhxh2
# DATA iYXvs4du/exDvvLfck7n/KskQdMLSx8LRLnmCFdLTvhZZxblgt/jb2kQ7vRxPVmm7QjOgrzrYNAW89vgX51/L3PajzP4aBAz4ObW
# DATA U/yF27IEsHh8bEXbYyly8H3/gN0X4Dkbw+wCb9mJczQwm4KIJ+5SScMD2V4U3wlshEP/DvsuJe8qb2dNtAWl7lH2GWYlQsYSjGOD
# DATA J73X5WM/nKw0zdax1CRIT6aLd4c9lDoO7yJ1XbYhZXo/cXKPJ248xTRlNKHuBL3dKYkLm6zsT4efHv6GacnAIPaQP38D6jKmDfsL
# DATA GMXwy+GnWZay/8v8+Mns69lDUJH9lS/85fDT2Te4VPBmX87uMxXZb/AdN/DrDn9H/4GI7HN6HYjMHtLP95nK7Gsq4Dv8dvgxFfM1
# DATA yMoOP/aojPt04Xe4CGo0x132XFiHaBu7XoiHMFy5nr1nwUjqj25jl88fBAWEPcgrHbHvOPTF/YGSIQ8VR6V5Dwl4Gd50wIUxNvk0
# DATA 7DE3Kq1on7M5ybH0J0KSGiBVn4TZQtYyIZMORFE60jLbVrQExpOmLkuNyukxl3VCOYc5Nne+oa7wRM2wl0HvmTtp0slMHJ0weRn7
# DATA +eGYExCwHDgzTFfVMZgtN2onzmKmhU035Of8ngSVxu29oDOVNJGecMcD8oOJnFmKeYz26lUaxX44gK3t92hyI4/knI70MnWGWGGj
# DATA gAoWIoVwABEsZqCyjGRN9gx987JTc76Jk1xqT4u+bGHlHXuZswBOzALQvGXHV/wvRIDoSSr9k9b5S6n8Y2r8U1f4Mh8TjbfZy56J
# DATA 5XMavGWJFnuB+OhjiUgxC7cXdZN5e9wNkz2q5S7vm2DRhcjTNJYRUxz1/SE3XF4LGSXnBmh2gnUJWy2aMknyNVnjyrz3DDjbeEna
# DATA Mu45NSk86o4pXicKH4QgEi7b14YBDcEYtfQ6OPCDl98eRPtyOqKjkktBGzUMeKj3oukI3F/MQRXuhD10Faw7JlohfcR0UzAWBAOB
# DATA 6bnMGQJF5DSI8smnHI+Z4zFzPGanyGO2pKZZyuVZwj5+cib+o1j4j2ngOyIzR2TmiMwckZkjMnNEZo7IzBGZOSIzR2TmiMwckZkj
# DATA MnNEZo7IzBGZOSIzR2TmiMwckZkjMnNEZo7IzBGZOSIzR2TmiMwckdkzQ2RWbdUb69VHJTLrdv1u+TkiMkvsOB+Xx6xJfVKu7zWb
# DATA rTu1jfrbzTQFWTVotrvZnixXqCvre43WOn+ugWRMfa5Tx/LnVsurUA/X6uV+pVUu0r/qc0V/TpF6Uc93utU8Uq9qK1OFaoOqUK5+
# DATA WFkve5UKKNi8aqU8qSBs3DqKPmy94a+3c9/UaGbo0CrrDfCSebVqcaPuVZp1kKBVGtRxlRozv9U3jnhdu9bcyWcrs0jUinAHfAD0
# DATA y4z2NnKIzKguMZEZVcoQmQkdW7wC6rXuenXp/m3mvKpaXo9fVatUTvFVNWFkk1dVm+un+KpG1W5Vq3yKr2oyFZ1uVe2EO/BYpHIs
# DATA 0jSpnEhHi1SuXm3WWp0kqVyaQi6XVC6oBOudRkwq1+g0g1bNkMq1m+2gbZHK1ei9reapk8pJdmFRthm0mquxB+Hp3Slju7TE/LOf
# DATA SZPCvRWQMA/9Qpb9rZ7H/ob45/qd/UJT4p+q5L6/HMlbaX1RWFO7Z3Gh6Q0S27zX45OJbKqRSZTD4BZzQl8/3WmRAOskg17Hs8M8
# DATA Dtdiq2o+MZzVVQvsuUydk27RKVqHjmPOccw5jjnHMec45hzHnOOYcxxzjmPOccw5jjnHMfeCccxhLoQT8vBHPrDYaYKdM7Rzm+c/
# DATA Mj7JcLzJ80SkFJ9fxtVb1sqXhb953iz7sLv6Y35ULdy1jxQvnUYuAhiqnPliiqMhi2oxLs/dk1d3prL3vGkX9LLQ3eFSTIHHvHSy
# DATA pWPfW6ysvVxpvFJpoDq6tPNSwM6U/EUMqqkZw80yAu0gCDpj8N3pZ0CSJzAEY4O91A32RYAM5VSegH3RJT7BmGgOOhqnGDe1WT/C
# DATA i6WrZPNplR26tZJsPqyu+oU7hZAGwX9FGdp31l5eDWlplF9rls9W1gplJH3xqsf+02Z/8/xq//xmpV4vv3Zz5TJNST5iyaWig5Th
# DATA w/3U7UXks/bPNMtrP6vW18gD6zCe1Wq1cHOljLv5Mf1M/2d0Y/amc/HMkS7HDFgdc63V1EHwaJPrt4rWM9Xg//r4X9Gx43O48spm
# DATA 3mCuhq8mB/G1SuNsWfcml3ru3lrpV1E4oGeZuFAqrT6+kvPKbjgIx3sKFLXS0IOJ07IScBECxPcHQJkQOgA8z6SHq6kJU9SzYs2e
# DATA FrR4eB6ZblmjSp7jAaeRKGqvgp5/bZHJyCsPiycu5yPoQTKG1KFjjZyhwS10yZpbUU8643dR4fo8dGlyF3LGqqOUfU2XqR8ihYuy
# DATA DE2jPojmkCIcUsRipAjrmKLDi3B4EcfGi5iLU3oqOBJXppN4AXDWlsb0FM1uQCWeRRijJ4FjL8aKwLiPxIpJIdfjUoxbr+83wstc
# DATA MEDv5Y2zasNcAdfPwaNXCpcR6Sc4Wc58SAbYe1Vp3qOQ9E0xpkrxlRhJv17Og9Kv2VD669WyjaVfacyH0rcMGlSfK06OCXlVPK2S
# DATA cPqJm61+s4vIoOVzzc7Xytr+mI+rX+d61htH39nkMps5ZWaw9/UBRmo3H0Q8r4xi4QzCyqFb5RfVMzEnFJwGblNy3HTgI90JiXF6
# DATA N9ZnrArFATlvXU4NyMm89ir0Jq94+63x1dN5qRx89EjRjkhMJN6c/Cmm94zHZS47gkgyRRPw/FIiXEJ8T6BulLGiLXkbOcNgzHTI
# DATA obPs/oSQZzMIwB+JWxQAL01hxp4B5AzjaTC5AYM5aA6CeRg0SdAZmxUsy/+VzxMmHZjwH6AJ9Q4Fx7a0CrJJwI7kN3j+wS2SFobz
# DATA S5xfcoRfkrA/nWviXJOjPY6nCnEHHY8JriuBzunFKHdvGkdECA8Y88msNRo9f8wgVwCcYswxA0JVEOS0vi+BSwOEpsEa0s5FinoB
# DATA aTY27bfw0doGmPBrfiDAc4EwzCJUivVNjaEJPTYuDXN0UfeMP5yimrv823R8QDp3wJxe1EARFgVFQiTukVa0TEjP4mJ8Wxc63Ism
# DATA 0e7IH7KqHgYwpBW8bzhi6DFpYlLtTXymVX43GgmyrtJ1aXJToUi2LD9prZgjFh0aCzLItn1Fg4w0QSXYJHaP3al9UJEDH25L+NOE
# DATA VmLPt+lFESEHwwBDrSG2t6j2YYetuoWVTxuP0gJDKSAkwmPDIAwU/4khem4zIJyiv9CYxDGynnDZJrH31LDsQGQLP4EltX2Zvwva
# DATA tIUM+0EE5tZ0s8RMSPLGZlAVzUQms/AKwvvqzehXMtv2wOCrKBukC/gHEPai8thLbjNsG4yaAibRQJoCzjtEb6PpWPWHKjikfti6
# DATA E4UdhqRmlDYQKEiXkoKKmDG2D6i1IZ904+yUfJeea/1zYRNRAXBxynSdsaGeAK6OuuKFAYeu3486srgxeHzZjJWnD89F3S5i6nrs
# DATA NIa1jGHBG053yEKxnmP8OV6EfgcWkDfiOSyTlXQXkxfzKz0wsZPSIUt7TGtyUROvgRpckXtNoESsJoKhTF5IkiEEtheJO2rrkJ7v
# DATA Tnu9A8W3omrKYZwxT1Rpdz/BVMjIgiIT9vcihY5IAhKZoDTEoz2sQxkwyPg0Ra0Ypj88e9qxhTlbemk0aGc6/6BN5+NyhT1ldGg7
# DATA 538xWdh1aAJNdslGlcz3xWxhzw6a9HMBqXoUg0Sc96+5vE6SVCyJkH3SnGJpxPFcSjEVfmM0bwwqZ6GRESQzYixmTdSzw6HBUAux
# DATA 85cZu0R4xchVYXxicZroffQ77nkzjC1nSA9AZg9glwsbGc2b+F7xTGDTSnZ6BAsvBBTZgbrpTNSbtzzFXoadi+nLroWfF2BcSBOC
# DATA UKxhcs7gj8MCYxji4QgzehyYZSYIzr5xVyXNhgz7Pu4iOzcRbSWbG6DFNhY6W9rsQkpPTRmUXBu4mX22jK33Q7PyYlqz/WBHgV/b
# DATA rGb/Mnsw+3Px8Lez75ll7OHsu9lfmF2MPh3+/eHHs/s2w9jhp7iSJTj7d1yefU4PP2CKsgcefblPFx/S5e/ATDb73ON7vmSOs3+S
# DATA +w4/U0Rm98GkRi/4lP79TBGZcX3uo06H/wgONOY7+8vse/qB7v/KcZs9L7asLHIsPA2+zltWhnkT+0Dkwwm6ODtvERU3wapHHWmV
# DATA vw+UReaQl+hRdIejPP4ojipZTIhYHgupzN5OV8PRmdk2bSwonjSbWc7AnB6jmcRUxpmXq+vp2yWDwNx9NRiTBmqLwuZBOmFqMwkv
# DATA CZ4/Qiuy8cesBY7YbKnBO3Fesy3PwjuPPQMzA3jTGEA60x6zcOwc4G+cplDhObCeSAXFzrlw5X26XzDNC5qnQue7GBITtn/ugLzY
# DATA o4u9DJ/ZkjNzvo2TXXZPi91syaY4njNnDTyqNaBpzR7NCHghglpP0AA4Df2/lPo/nvZ/gspf5memJyyqs6eygk6D2SzTSGY3o64a
# DATA Z6sFjjPZVvZoemKmnhWip4L39vXrV64V1MFStTPMI8M5oyOyH3hnh5sBDY2gRMymNFJjqSMPuk+1zl2W3sxMBY/6GshgSQMALQvb
# DATA oDmLjYAkwdlwFHQQG0kaBbYxUOBlCmHhwcAYtJV5wFYBeKjEPBTKKa7/mF4Ts5txUGV8MOajlOqeHcdv5vjNHL/ZqfKbLadrlnJ8
# DATA jmUgP1mL/1EM/hOz9x3tmaM9c7RnjvbM0Z452jNHe+ZozxztmaM9c7RnjvbM0Z452jNHe+ZozxztmaM9c7RnjvbM0Z452jNHe+Zo
# DATA zxztmaM9c7Rnjvbs2aE926hvNJuPSntW6653d54j2rPM/vNS1GfcuarzmCVM2Lbq1cRhsUqzmuz1mnA5Sbe3Eh3XaQWNoJuib6q1
# DATA Gg2h6krTN9Wli616yLulHsJ9Fdejlj60Vo2rUU/T1uXxhTUtvrDKRstwUCUY0n5a77Qq67XszGnVaeq09mTOWc3zmzsbbT+XP21R
# DATA 86rClHZKzatabF5LN48eOrHm1YTj65SaV1NPH6t59NBjNa9WrT4Ti6RWa53eIqk1K4+xSGqt8mMvErt5J75IEs079iJB8x53kdjN
# DATA O/FFkmjesRcJmve4i6RRaT0Ti6RRq5/eIqFaPMYiaaw3H3uR2M078UWSaN6xFwma97iLxG7eiS+SRPOOvUjQvEdbJDZha7nl1RuN
# DATA O/XmXm2jfqdYb/aLlY2mV2/eqR1FoDp/ETwKGyZbuoYNk41miw2zttOsthqPwoZZDvxuxWLDrDWDVt2wYe60251O22LDrDTk59Nl
# DATA w1TJvOLdWcEete1m+DHZYScT3Q6qbfAee07aRKJU+K/Ze9KpCtktsxZvmZVaSJWRTbNEqWrDfGHJTd49Sz6mvcD8ZMP4bvImd0d+
# DATA P7FHd1Rz1TM52/PZG/ROfabPs3fHUcR5GZLyoooMkYQCMoVgqyFL9ammXXK7YGNjAxGY45F3csQop1UcNszEnrPpQnN5Px1bp2Pr
# DATA dGydjq3TsXU6tk7H1unYOh1bp2PrdGydjq3TsXWeAFtnlppzN9xRBIrYnYPpqcgxNQcVXTlTKddbjfXmuYTPoh7jw8N4TFMckmE+
# DATA HeLKKxU8Wa2fU9yYF9UxduAHDCZ7vQPDc8UUiVQTmldvIr9/tcq0iG+Frwul4iWcM5dTysPedOwBsNlTL+JnVZXmPb/lVRs/M2+L
# DATA gXbEL6U+uBMwVecq1eFl7PGv5ZVkcxla50wdIIwDhEkAwmQPHTt0GIcO8+joMHORlE8TNUYLa8BByHrBcDGSAxJtOPPGgpB5dnDM
# DATA ngShoahKJvoQRcYoHHz1CCJB/WRCzI8TlG0II+QSCVYsHkG+qazvNHSC89kEjToHl6D6jLIZsGQIpaib4K3+PHz9KEJEqzjTFPua
# DATA aU3j6LZUj9EMsTYgARAVFZNg9d2j66ufM5U1F6yaLtfpS9ZU20G8TgGUCMiR2G4h0TUMg6OmS1xITDwZXzJVXz+q5s0FtZ5L8mdE
# DATA gHaZWB+qQX7uSf/ymP6MhRgY6QfJRHNMuDx4eXQMvA5sAx5Sv88+AG/PMCCM8jXb5FQxWjSTmiA3ktybgre/R5OPjMPRbmCVpnq3
# DATA 2yVZuzMdIbaB58i5GgVAaAonGuBHxavF8xgzLDcjMdGUOhADmXEw7XlW8i5EfQ6LkegrKLCeQcfgP8WgS8qZ68gT/kjhIsW2TEwy
# DATA 26d6TUccW1XgQ0uwBv7QkGIc54lzBOY4As7mfyFs/uMynTwrSJF2psRiypO3QtaYgpbI+9EAiRswag+trX6wkPvk6cFLPl/oakeh
# DATA S6dyPE6D+CQLoHnS5Cd5OKS5BCiJsdMpMTKR8wj+3oQ9r02E3DsY1XPhHa+LaW0MjWPCfSvmP6arDBlwEEQigvHpT2TMlbm5DB3m
# DATA tdjt1vSKb19/91LBu3DtWkHpYVkvrBYUljtILMUvEqDFIVBCfY2kykiNNAoG9jMcx36DJrbjBR5OoLYXMCpeE2EgCW+LySK3rEqo
# DATA SaxbtAUk0IGCR+XacYOoYZ0AbH7BoA1E0EFA9VN4rAWavTRd9/Q2m8CzJlFZF1JzJgXIEVXXgLNiTetqKzJFNrjVAcNA4hlCRgqz
# DATA X7Dv2YAeHShITFXLkndF89Sg5rw7pgWZ73X9sDcdLWKzvCrFYONqHp/lC2SB2/La2eDOBs+1wdUkcZF4F4lPWHdzjfdnB7+d5zQ0
# DATA dUzn7HsSKTQReInVhGMk7kWsJJPg4zqEnmY/mw5BJ1jyfoEc8QND0UJ3dKZtgMj0oYsNtLGJtzOjMds7SwO5x7gFsjzx9fyr2vC7
# DATA hmPevLCBXzFWBNjicShZ8OoZYyVORHpPRvgowNx4VVuC9WRvjCLSwbSw93JveF90eheszXNu+QAmG1opWNwMNo1bz+CdZ/T7RRml
# DATA q6EMVWXAGYuH39Q5/4ZKTuQZXPCgVrok+yMaM6b9pKk26fCdSkcUPFHGBQ21DZ470BSP96TcjqrWnHq86w9oTnVsW9BUZiuGwE/9
# DATA LlWwTTdjf9GIjgKAd/Pmgba8jq7IL8LRZApEdYYSt+qgBpjNPJ6tDCnPMmUU9Uxl3hsyooq5gSZ5MGGU9CErT+qgXk9P9bFVnzNq
# DATA oM6oSTeHl34x7fc1befFfS8mn9/pk9LXXk7M7aORxBVT+3gvmvY6vC7FnB3A8kPiOVwrQVeXAS55bF+SBdyLDvpcBNnn4LP2AQ5v
# DATA wdCDi/5X0Q4rTgUxPx0wF6IqaREh+CDaV3jl2nT2J3u6+h+MGM6e5r3H4CYS7Ob9Fh035qAzWeNUjK+jzZBSJOz4HvzAHKmxjQtK
# DATA KJAs6tvZMQJT/QABdlLnwUDf21Fcj/He4KLGvCuhaNUeX8DzEVc34X0VWUfF9H5GzKuwF/SGSp7JhqclixgGnxRllCBVGAb+bYyw
# DATA SEzMPexZdoI+XmB7WIpYgUoRf5Bp4bEKbNdM2TE28bnZ/8T8DPtLcoj/sGz7e/du3bs5WHnpRz/0P9T1QW8bAiMcTEGqOjw48Xdg
# DATA 77JZr/9I7Run/q2UG43qj8rxnx+VK5X1cvNHXvlJdMAUa45e/6MX889PfvKTq1NhiGiTAAk7rGcwKVbGnItcZNqPeIJ4Fy69Q1KD
# DATA tzlpfUe9Dm/h0wMlKuslgUoh23aXD9vo778i+1B/jsYvsfaC0O+FO566fIW+6ltG5sHxdEfFZ/QVHMmCOtDfp2S6vPTSB1e3rly5
# DATA eBUJ1CsrKy/xGZuXVIJlV/KqOdi0Ss5kJzjbHa+scTYjToasgIPvDEnFM2D1PdPuheTBrJx7SVKtu+MS+gFhvmsHg/YqHip4K+Sv
# DATA t1asDNQVDgoVUXox7q2VtTUdXyoFd8PJamXt3EvpvM9k1fgc2bZ6iN5A0nF/wG+OCwra6K2Cd0NVJv/dtwoveZ730UROkZytcLpD
# DATA oe/ffX3aRe5jpVlr1Qu3ycq8Fu4O/N7ZlWvvvPXzdy5dWimMJ50wOntjha6TelgprAzDIf5R32/dW1PdoxJTg9GIVM+vf60TVcdc
# DATA oH2BN8sl8XV+l0gO8WbitJZ+vgNdMInUsQrV/7oa/OBrPFAH/BIcjMLrfyyHh0rh+JrfDd4hu2gXhxRwewn9dQE72Wu4M3XNe9Ur
# DATA 510+z6dtctugr6i67sOQWVX1Tb+R7o9PbaWL8u69hEn80kvkQiNMuc3sRqvhYDwkLbwtg87O/9pZDDG6gHfQcQk2AH8osTUxhgu1
# DATA ulJcWcMPvWCwKg9SQxqVKq7hyVFQQj4BpxGvjlZubBX/q1/8u3JxY7t05ux/Kt56ZSX5QvwZ+XDlfoGGXcTwr668M7iD0z6WJOFn
# DATA Vtb4GaWIN3mlJxqzphsht/BkWaWZP9nGSV2qad172UNCr/pncR24XC+42yZbdyyOpKoB7M1RB9IA8qjE2Q+r6p2YOtvIr15dW0v0
# DATA 6ZhqOvEHbUxFfrzg4fSA6U51dY2mnVdZqneUq6toTIORqp2+vqnreaN8S37QNyLnW27iQ4kr73RoWFbU48HgTjiKBn2VG27fR+5c
# DATA N9ylez+6tyZXLg7uyJEgu6npSeAXuzQDbn3UrN+jm00t1vSksbrGenmqe6xf1tTieZxOwmloOeDCX+Gsi9AIB3YPxK/IDiPfX8DR
# DATA W67kCtl5eFqK4Quj9IW75XLq0uaKylmRa/H78pv1/mA8HUJdkXdhVVM1Cn/4tOc2tUwkBWcMrtJrCl5lLd2Y/NW6fctatrdepidx
# DATA avWomukOt6cPPWfVjLu8ROoxGHTUAVSzXqf9VQwybimRs0Hijc/5YeyxD0Hdw09j5KuN5hLL96JVjbwl/FPsLSGw4fUVj9cbUfs2
# DATA TtfgH5p89ODogN2ngvjLbZ6POMmAgYNQFjI9Mv1LqkhkYJHsVWx5sGXg0zJ7n9okOifsZwhJac8fMWiGDIW7ON7zkX8ly9VIv02q
# DATA 7CDgixLIUqZL6XoA28UfHbzBwILR6ICB7cK7myv04oHfnuJAudHkEN7kqnb0zXEH0qhtKyuGpaq5Zc07463YM808omPmEcRJNC6B
# DATA IWxVl1PAlfe2P7j63uVLv/R+Ld8uXL24dV1/ufhfLlwqeOUIlB6mTG4d/dztcGnxK0g87UvlabkFfj85G+WaUpRYh6Vf0cCtqinz
# DATA Ci/N+CUTu+Hc0YpPbdOyEks0YKs3Erfhz0qHZwnEpTyFT0UJ7+Kj6fVS3OubOOwF67KEv+qkkPaCu4Vs0cWimhJcupZXZ/G0+cZv
# DATA M+a0vJzc7GJnFA03t2Bx5ZU71ls0ZJ9uDiJ6z34Rnm8IIpmxlEIjV8TIrbBEMwO5llsgaklTBE9qm1eXolcNvsNM0QofP+OLMrCT
# DATA xd4qIFgwmY6CbUmh3Lw+mqqD1/qjWJ+btXJB9k35+lpyIK0VowZVG1GIUw1Xk7cvp650mSkJOHeFLicm2RLzQo6JTWwpKfaFsujT
# DATA 89GafmyUSaf7k4nf3rPreis7anl/lu3zysJOVyfzkgb28v19s/NRpdAQy4BtaNidg8mq+qbs5LPH6FvLyZRKZbqX4QDil5hfu0j5
# DATA 6KXEA1XbdGy2GguGaNSX8SE11g6Sw+NJN21aT79x8ReX37906ciRoyfJS8p7Mh6vhh6uNwHgsKY8AGiiVTWN2SmC5NYedmlrtMtR
# DATA /Sv8ixo6uQ1n+bZ99Tv5AEVldFObdO6FNTHmPcMmfO4TdBtsMfUg/4NHx6oSCYHN5zZWY2cG95VUfQqefGMHQ1mzd0HD6V3kfwDE
# DATA agr6qdL4Z9543WO3c8zUoErU2gHrkvcelLbvMXWPh+ylAaKUbY/0kz8koyZliFzj4P5FeGErlyPkccczsm1i6Dt8vRuO+kFnBWNE
# DATA E217G+bANtlvm97K9jZGbHt7RSotw/eMhhJHOMXeD04j7Ldc/K9aLVfq6fgf/V1z8b8n8eenPz4zHY/O7ISDM2Q6eMODyV40qL30
# DATA k5/8hIE7hK8Wmy+yMYY9Buz4YrsiGgaa9FYncF3VZpTH3lavR2JhQVQQ2xTNuv6GnCb9ec8fIzaov4bABxtZQcBHjyfKDqL5ujed
# DATA hL0FwUZ/ZMca07HHyd5IiO4SwUiuzXTUo8qIUNRVomvs15HM4H0RTxzzqXSjaMNYMSqJT/23ZcsuWMvkzng7B9zlpqPZCMcOySj4
# DATA VaC29tBWcSjHPA6iT5DmtUrOyziO54j8y6mOvk09yuA66Gj9nKhkK5zCbgjfYYVU2DVE2uYKpzmtrOnyxPQfcjBT+eVIw9kU/0Le
# DATA McFxlYn2cLho7X/KT6VwvD0+6COLZdWy9riZK7P/Pnvgzb6c3Z/9dfbw8JPD388+p88PZt96h39PH76afeMd/uPsweHHdO1L7/CT
# DATA 2cPZt3TL97Nv6Hb88Mns68NPD/9IP/HT3+DrWQ/WPextqYFSWqo6chqx1IepvSpfxsoyYy9zO7LtMd7Q3NRRjO68SEVABoH0c2fa
# DATA H471b8EAu4/b/rgdhmI1IBEMGnCzql0oiZR0CuyyMuaSckP7t7Goh8b3LMXOJyl8qv1mokU5Wh0+X3uPhmwV5WPo5jqFuIGcQVQ5
# DATA ORmwmb4Pn2+T/b2lnEV02lrez93eFHAwiZ9QB+QKr+p7qO2DSMf51B2jgNnANHKUDKsdeKF7uP9+TBqe3KRk5Yzfvd3tWG51ovuU
# DATA b331Ddu3fuOdqxcvXH/v6i+TVc74uol22G9LPpdrCKtnmas959nMM9JYLLQSz9cxd0rKj6I7pgNecvyjWs+ywauiRCY2jRCRgkVD
# DATA HKg2J+q8+trZOIJ1K/GteOujcqFZuWf9vvbazdLaK+rCrY+qhWYNzoj9aksK/M/Z17Ta/4PW9G8gD76gBf4trfjvvNmfeeHP/koS
# DATA 4Hv68Xu6EYv/foGu0ZWP6dp9b/YQd3xKnx+aWDJLPonW9YBJsqo7gdSISUvchszXixVxK6srlV+VCiCqgm+sIG1zfPbMGYga1a+m
# DATA AKxs8t7DM/SulVv5/VxulDPd8H/OvoCkI6F2H7KO5J80j1pKfcISktr/EL9B/v2OO+Nb9Bd9nX03+44k4AMTcAYj/TgdsiysJILK
# DATA Fe/VTRUI5tvX8L161PigNg8xOg/xYrz/c1Tz/rLVjyW6iP7Dzw5/AyluBk856lYYmUMgEkbmitpBtgkD5fC/GQ+Z2ik/qEmQ2HYx
# DATA Y5haPYkib7TO3rKL0711IF60HTDNG8pHHsivLP9aA+6kl+SN/3bm1itrq7QYz8Rrr7T9vxfp6strZ15bURHXTIxaCkQu3QDISrsc
# DATA 0aXe/WilBO+6VFq5J2m48U/8yI3qLT2TqNfWjmh6ur1nE0tbJg8fvyjGc8fj57CYD/959m0hlgB6tfPKv08330dBdBtJhtnnkAFK
# DATA PlDhuq+/OfwDzbDvMT0xc+n7Z1avCppg3kqWtlZuYSXrdttdiCfDgZqoizvhiLXAHfINLS0aco8b9aWybajGh38go8ausYoGqWg/
# DATA 4AVtaSe/5ok5adbxJN2xlr4Z1sXNVU2B1JU43BGSmO/GN95UoluwGHliqhHAU0bAYi7TtMR13oOg2/jfzc2shO7qH9XN46xS+ndp
# DATA xuGnOaP23eGn1Cc8jaGWvuC59QdZt/n6i7XTucRvNI2pwx5IR6LozJQ9/IMnd+CimQlquLnaeaNNruLqJLodDJLjO38XmcTFzdLi
# DATA 7yQV7CLTFrzU/FNIdmrZ1pV3ivFiXGJCqBatrmxdubJ95b2r1zdr5Ur55uDqxXcvb32w9YuL21e2Ll+8tP3+1UubikuGjeF9/05w
# DATA tgbwhcFKYhWuxE9SZbavv/fzi5d5x4AbIZb3O5evX7x6eevS9t9+cH372sULVy9e51uUE1riW7f3grurNRjryfJvDq5fff/a9e0r
# DATA V9/7L7/crNwcvLt19b++vnV5+9LFt7Yu/HL70juXf7598fLW65cuvrHJgK+8WyKjBXczbYXljRAHzFUYF+6MwpfVBhorb8TtlFVB
# DATA 35qNRq2RGaI/ieyMhY1MzcPfywyjGUxl4Ud5Pjko8Qt07SUrl2Nqy7RCWYQ3zGSCsVhdYA3SjIJCpCrDSPiaJs53VO8HkDnfHn6m
# DATA jEH1y30d8Mgx/FR9rX221Xib/GzS1PjoXnbH2ty8aJ+eR+PGrYR9jv3n/L1n3kduG4y4RbvJcfVu0FO3GFGOn5sr8nVu6bba8Vq1
# DATA NriGQTAak49zJxiNQnLhV1biAIZAOXK8Qm+fRkjvDduS3c8gEiZxVctQbydAFq+ELthIQUx2M91ryDzN9txlec+72MoyBqkUAI1M
# DATA z6wkPR5Vbw5xmS8/zt6b0VxfspAlvUQzh2TOA5ny/zz7V5asuARZC1H8BSIPtBTIAEGhRX334R8TojqhjnkQpA58VfXfONsPqsXX
# DATA ggn2scc5nTGWuaRmolpMusCsXvbYaPyO7ZqvUDlYDyml8p1qEP6h72ozHmYm1hEteLIvSMHhISoO2god9iAekvx+V7kV8+u2TM8r
# DATA VfA11eWPojdUJTLNEg2cHgBliutKrGHmVDKO2gABrhDQt+ZGkmMZJ95M6k0TBlzNlxs3Vt7Yur71+ta1i9BGK7fWSvpZe2dk9efB
# DATA AYfoCl4mZJh6n9niVCOuf8pVtDRWmKbf8MhBdLMwfCAGCGw0XIxtaRlQsixJdH7pJSoe21aqHvqjcZeN48FepCUgIUsw/ixTEssU
# DATA V0zyE49IahXwZVWEXMFpmMBeDVclp4PuC8fcIQjGpVILZOMn3hnWO77Y7grmv+syNc9avmiLBJTImubtdbRq1bp/+TW7VgoFTjOz
# DATA y8ndO3fFzG0S7+D1Qsbgod7nj3po5BQUrnCFde2lZlvykFZMa6moJT8mUct7eS/DDiNCcavpbuPEqpW1Uk9cbPh/uj5JpaU2A6Te
# DATA kvVg1Y+x+nVRVnPoOjdm5Z0rW1IAHNG3etGO33vnyp2mvpiqNTXOzGF6XPeYsu7NZV2lbMerGQ68cHWqVgUZwQywtsbdoaeXHUdm
# DATA Bwa3lKYDMrpXX9YFSUAfiVZQaWr9cHyYb7dllyqJAwnzg0HxKs5XViwkP5HAGPkJX3OM/GGueuAfRAuc03bU5yxi/8DunS0hPIlP
# DATA PLCiapZCSCx73SN5SkL1wKNraFSQuuKfYb/O0w5zpJulB3S1bEmrqv3IgjZZWbpPbjDd9gC+oKW4St7sX0Xzfs5V/x3/8JVq65dq
# DATA VL/ikWD/5QI8DNOuyxevf/De1Z+n7KW8LtacGZFqr/o+5gzHVXX7GhJYxXBsiwm9bWu8lGGvjOIxq6vMm2KbJbs/gmNRa5knxECf
# DATA +xAnqZ59KZO689G9hPQ2UcEcUzubWsp3i+jLygE19v/isR8u7ukDs5tq518mQjbGi2JL6mP2eR96P7/4y81fbF16/6KOk9CFVLoM
# DATA ewKGhNp2CiReiYPsTHILxyA344dKWNCM3Jp/x3tqX7Cx9b1EJT5hR91yrlRsVqI5cLy+WlnCKeF8U90aEXeJ3K2kvxLXdGEHp9xU
# DATA +vh/KLePo6XStdZ48dVUA+jp3xrHW6e1U83sfVJ9sCHeP31pYXJyIoVaOd/J/HLLk4WRi278kkXcP+oYUUaOiTxGm76XplOjPsvx
# DATA auNli52y7fGeX2007dZ0wl0cKdzU2/QldctanOpqbQPzTtjKaCd/aw+LrL03HdzGImMzuuf3dzr+Wb2jx4QIVvL/WsHbWUnH06VG
# DATA JTkovMrlJdqlft8L7sons1cjx0G30RBSqXH6rHLeo2iSTa1Vu2Y9YQwRkTcUu5VjtsgsRkuw/cs6eogdajxAX6HBhvFO4rW3t6jn
# DATA rr3/7rVY6iLKOExsai9xTEMiaFLyWlwZruZSARCeNPGeOO+e8ET/XNaoTChaCEZZy1YsmnvGbgeOJEgib2L6rL2y4nkrr0gNX+Gs
# DATA +1Qt9ZjcYUiAbRmauN8LokUG2NtekSNqRw8TZ2lrQ8r4F6Non03BTN3tpIU1CZtwNrJtdc/dKqFx8ItdTkBd87zV1OisIYcu2p+/
# DATA UaK3AdiMR7VzLZq5I6eF1PeWDcPqQoWND38LDfIpSa1vLXHLzIib3INn8vYheBc4byrqH9S0pqsZYYEJrvc5ctvyb+laKgtNaolA
# DATA /6JZOC+8YrWOu5ENbN02LRUU8hTp+zhluySHoUvIslCpupMgfVHnW4/NFWXbJG401oqZshx2kllrWx1SD67iig6AcYaH3mTtJQrh
# DATA 5AOEtNIr+v3B7QGOzBvsVfXESuqEj2r3q5vpKWZNLw6168FIjgAu6REQXZ4OmnCnaU0n6yvbj2v53cMtUwfl8Qj7hlZT5jf/MmOO
# DATA 4CdVAemHleRwa/2wohnaiyBwGK2GIjBDlt6ATOBDLVzQDT28DPO2cmttLb9Iq7mpGbIW+2u5T7Iq0IEC1OCGfW5DdRvmWTekmo04
# DATA j1YVfUuOYOKtLPZ1ukZ8gk1VSbVBVSsxEuaZebNywbOWSByEXTEJrI5Y5sl0byDGcUNReazIRhxzw7ATIi+5Icwf0nq5n9sQdFZu
# DATA JaSrfkDmESYHh4KuRkLil7Yhks3mw7Q8BYoj9UBq7i63oP5fpVCVSP57klx/IaOYXOXDf4ilmIQqSZizr0zWGbmjME0zcpxloJGQ
# DATA YjonXaxhQgsmt0CUtGdFmTzJZYt0f2cc9UBqZnWQetKUewYXXlpKSZBFHvXuMF3PeHsU9PxJeCfYnkT2YSUYAol7eUs1e94pYdIX
# DATA jbWywJ7/vTKI43w/MeI/xw4r9ywHMrB7z8747C/QO+K13Of+/tzaRtSN1YuGhVVWHR5dYVZdn1HZ5K2zj/8JxOn8CifN9GRfvaRm
# DATA wCCYTkY+0BxkJuiIBNm1BtAFUD7o/3hvBpB+uwOcsxUyo55/EIzGHuhUPb87AZh4NGAWV04LPacQU+QkuECemBeZnZq8BJtYvmmN
# DATA qZ8rHfj9nq1K4x/kupzNKM59bu7v9POt7CSO4W3OeCaunl4Ic4c4J9U0N76q3pZcl9ZAxG6gNbM4lsgjdETpmQxBNfp8HoMqmjpD
# DATA TfKplTxEze2K/VEsuI9WNITRylnvo3txJETvObx3bdGWQ7IWnIya7ln181zL9j5btA95dcKqNbnmOubH1gaWyW9Vosi3CDN8bjZ5
# DATA 1AbF53Pkrey0ifv+BcfcJGzJsvhBIhCRzISJBytvX1QhB+mVl/EjlVWW76JYylPuW6Q5X0p4Dkq/5alwrqT3U09Bywo4kkL7CQdF
# DATA TnY13asAtsifvyNIRlGvY6CTeDq9lNapR+Vc5zopMOo57PD3CCgf/kZXoJjxLeUIvLYn9FtVxnS8flWP8k2683LMzRsrps+xnxZL
# DATA TtUqeVviLtiasA3jlyWzIuKj/8Ye4fyIWm353kionfl9oUMNlizVNlGqBvGrTdL8XPEjlhMu22ZTHCRMBNeyltbZJY4I6mlszG3O
# DATA N2EsiYSZNz9YekSixtwuM1nKGg7arK3km9ON0PfnWjP2j/lur76DPRV5k/yS7q/jOMHZRi7h+SbH0tScoxtMgkS6gcG0g1V9JsM6
# DATA TdmLD/yrLSQTPtZjh9A/3CF7t+kj1mBdZcwVvG0gGujwzj3uFNw2Jyb1r9TiP/PWh2wa3ddpql7WfPo8G43SrJzJyWsW9xJOAB+9
# DATA lF1aPV1win6uJ2CvjvjZ3KmT/Dl/8sT3cE/ppZ2tcm4w5UrcfMsN1hWWE4v6aA8/EgjatWBZT/t2TMjuSRatVtWSm/H6xqNE5/I1
# DATA Vjk/QBn0qef2yNSMy7ErOQr7PudQzzewrOqp21Meoi5E7SQunr+P0OsAGPQH3lQFZ7S6ZaGbzBLQAt2usxDopIc7eRxKFqNcsxs3
# DATA /4AUpl3yoJL6J/a9fpywkfNjzzetw0LWCjGn8Gucf5d8kcSm4/frKPjl9964uH3t+tb1i+Y8zDsXr/GKVUKUMXqgYVVl4nZxkH2e
# DATA cD1ieIQ8KcnHuxJHiTOST2+H8nxI7E+bPar09qV1LEwdl+mHYyBGJw+BSahvnL/BqJ43DklKbqizSujI1H6MqpVGZjGH7+x9kGzX
# DATA SVg/t/Gb3AP/m1eO1tfXY4/Y9LJ9SvtqIFAOCr43uBNG07H3zrtbb10seNOxsBMgH3A/sDibBxMV+6PFMgQkpVWiwM15H06jie/9
# DATA iqYEFDsP5D4fzh4F1LXTgI+AhwwdBAqtjvJi+VjGdBif+VZnD0UEFFIrj9MJbyXXqPbPknfa0cFkZ7InvbwHqBUpP0WDqWo2b4D4
# DATA vkLGZzM5tD1/sC3ojogrbytrflWaVpBexsH79l7IXOxWKqcC/lACobOJKa0DB+qLFaLcliL5BzusIN5DTPigM6jMOVVahpgFlqjZ
# DATA DwGWxmO67486cTwBe7/zQ8ISVufDJqo5i+7LGB7/wikYdsDnG9kdlZNi9/Umr8dW2gNyPj+VzJhUlIjzROLw+B/n5BSmdnxVZ2s4
# DATA qgSOWx5cG8lhYVyGEB7/GthUv775Nzn4bHb2fCK5REKLqNfD2Zeyi40gFFnUvJH0aU5XKIcFjjefIMlr2h0si2jApOtmqNTFua1X
# DATA vyfbn5el/srqa2dvluTj2keVghz2k6eXabRO/5RkpE94+yK/qbLNlG2fnlvbcUOT0y3T1swTKt8wqSKynZJ+7hF7J13M2rIbirLN
# DATA Y/dUMuk3x/pWACKctCYb+CpjxiOZS9buKjIayI8frjIyVyItvUQqCeegbpRveS979bUbZ+spMw0FZ3oFa0J+Wdi+f1dZEXCz7/MU
# DATA VsOtzhuZliFu9IVEk1TDkfuxaAfynMTtISn+w0gMmlK/lcWUyEL+QgX2H8r5c4n46pkVAzKPk8vH/kXdTCpwO/VAchrmPKOpbtK3
# DATA qutb9hOFzBvi3aT0PLVusnJWmADArqGSZIkyFUAQ/ZZM7RwcpN+ikiUXrID4UHByzx0YeHE+hEnVTFQj9X7e+KOuSdxkPNf0o+mF
# DATA m+65uFOO0Ui7rpmhSBeVhqiUAbUGY/l3qWdN2hG6QV8zPWDdlG2SlYecmaV5bzpGXkoiu0HOav8DxxA/kbOZKfmU2cB5YM4TpiWX
# DATA EBygvsySkVh+uHJNzCvgBScXT+JH2ftWlpgkrZFNJDcaA42zu+NIajjQvZVeLfZvplC6bmo5p5cz/fk/qH+kC0z26zd8sPDPmZMc
# DATA 37NI+pT//s3sc2XjHLcvh0POqrghjCMqN31zM645J+5l9rzVjEicZMf8kwLj6ae+m4ltzbi5s009k+mb/4ea9Gc+XHn/8I+H/6SE
# DATA t+4ffaQhN+r2VznXQgUoqwGp07/hGfsplfQga0Z9bc68KFSWzTmnxlSK/ZUr6sCghfCqDIVaVcefpSgOO9fLG03dK+09mTf8Hsmv
# DATA k323mwxvdpOzVhjT9Fa2V/4l0eI5kyI3mv2QNR8nI/IFqw3z4vYqxWJBcN7Evuc6USo7MnGuLjd141YuLIEEIzlyX7Uln0pJOyJm
# DATA +d+tU7ppE1v3y3dqnn2ciWNmRJcOZZrYlobnV22X64nmc8UKGe9oHFxEku8VhnRcWzO7/2yfwRRD0nQJSEW3g4Px6o2XVTnqFbfs
# DATA R0rB3QlCwcvtL+tcPjv8ntq9MI40Sj+bSTdbenN9CcWRDR3nH7QzNdVx749ka4TTUGX3DxlhEsw/m5Prlqm8yVDWIh9869wRif3n
# DATA lRLJgZW4bzRfkhy7STvZmKHyaS1Pt5hUo2R+bbwu5G55VEOFChB0sld1vrLY6Xy7BC0XZOBLi+O0+6UQmI+z88MDahBv5+7xMlZL
# DATA 7iAvSIExleVRsnd97QSXODNGGpsYyTiaY2dq5c/85OqTl66d7kqIVwDZUDjUEueAz+uvRMbZaa0Lkh8qFRMAcKVOEAzxQQWqrEzB
# DATA 2KCCZl8paCmvTosjOvzjzczFeak4c/IDPtNJ8t/xthqUOyNTeDgrRX32FyTj8HHR+Ij44adatdsYCZYxmJMEk2+16cW/qXvlRrzA
# DATA b3HbY9CK/KWlbs8cikkeQLFNlW/NtsQ8bZ8wt+fNlaDbDThASJVf1ZHDo8TVMi0yBS9q0/x4D758pdvDdp7JYZ07+rFvcX9ecxk5
# DATA GmNrqicNlOuJc9bZI0hyU+YMUqJctHU15/R+UqCr21OIAInulFukdmEU79qU1FhgUzOQo7Qr9gQugg9wJf+w6eYmuyhzhfcx3A4O
# DATA kXwrJ1Iw2eLTTuqkmjpykwfqYWH5ZtedFljJ+ZWbSzUKaP6HMEAxeVMjqigs9IlSNRj/iQfjRvlWaWTQivhKsWLwi87qe+zhsN7F
# DATA aEj0bbI7EjRv/flDhUneCfkyjSkQ+QHMTTbKXU6U8zsdvkIGWdANb6/k7k7O/jR35WKx/45mPwzTf+SzWjQ+X8spUB2h8mQFPcRC
# DATA 4SXCB9BwH4NpfcwZlH+0faZPrYFR43BDdSBOcvGn9A2lYTRcXdmZhj2wWfAmgrXnc30vHCsRApwQbCFEDFeHFCdG6DcpHvh5NIx6
# DATA ssUNjaltBau8EUhJgwHmh6ADqz0ogPsPqEbAzezh8A4VOGD2AXN+DJjBpBBL2RbaOPto50cvv5x34DFtfcUsENChlrt0VjlvBpRw
# DATA BfH9lb/5G3022UxRW8vkSV1bf5hoByplbUvZVcwWzJ78rbw6Kz4OuldgruxyVJKpPJY8N8uBcdEUVjhczAJdu7znXkoeqLfs5Gyl
# DATA s0flteSaq3pzBcP8jlowllkdkbj5GdMQZuzm9rnZchyxdNR3vnP52vWtyxcubl//5ZWLGFZIM1ohLMgERTcSxPv2XtCZ9oLRyr10
# DATA 1FD+rO5EUe+IqaeksFjCif7U8nlz05tXhJFBa3MqYPU89YeKjeJN9M1ahLIK5V164q8llK3qJ8QRTlDtGiMnPlt7XzbwvmScugdk
# DATA lj5Ux4MT2VOLla+g2PKyeMVbOZfdG8lGXROHR2WbzCTTfj5/G9Xkr5vd4GSKVlYenLXoZ9imzJEuqTncMyo7MYnj+JllX+KJRLQM
# DATA F5YOlR1teH6fZ3g+yMek4W3mr9UZ/SOM6wWi+yjxf4QgF1es3fPFF0u8caFooB41z9kCncla1Q95a+jHDISTb7Ys7qPPEx6LBjO0
# DATA TlFk9+bjrd2/YGxygCvO6Qn+rfKKeXPwO231YOdPgPmOOeNTs/6jZDee9Vje5Cn/e8mDFEnnmL1cG8vUnJ+CoNvUCRzZ7b1NiYb/
# DATA /+y9e3Nb15UnOn/zUxzbyRyAAsCHaFmBArspibbZkUQOScWdptgokDgkEYEAggNIYhhMxU73dE8l1anu6pqa6qruTO69df92nDhx
# DATA HnZ/Bekr3E9y93rsvdd+HACkZKdnOk63iPPa7732ev5WJZG60cY+CvOk+isfmIdWhdiQL4j0TxG+W/ggI7wdQKIHhkf55R689lC9
# DATA xbxB4YvbROgJ6cTqOwvK8rd8wRfbhrv35E7b+pnmd4z6vTmpmt9rk+qaubiuHtz8RuvwwLmjf6+Qn5ypLE5mCNVjKsxnGBjxcXK5
# DATA 8+FTJP8fk2PE3wIeinYFsPDpPwkiJPYLJgAYYdstGTpxYTwl6skKRO8Y9X/d9xtFXoI8N1njxGvQTbdiAjrBCcr8Vh+TZg0VU1aV
# DATA RWmawMGrrvUsOtpX3aFeQbN418Jb/LPintW71vMquhUm2hdrphYfNeEaStdAouBlENRRaAkRQLwoaMZ88aXbJqE/3pzs0Y8bk79k
# DATA B/1HOrYZmwVCrgcAbjLihPrsSDirDsvyA6b9qK94sFfBXfiW4l+D6m1MawCrbBvuQSK5R7oDdvQFnChGn4GOYDFDTl2dB0p2/gUe
# DATA D/r4wH3F+leLSV2tygCfEEqocIZt88FXRiY4yiMKaXfggwDC3OJ8POFcHzGHQXAktEsSrjxvJwQmwQhO8yz3Idfm9MQrjJT5N3De
# DATA AStb4ZEb12KHJkdo5KxwoJJ4k7pyUPRJ4CvtGhvMiBwFAJWsxPZqcZXZhQ8jAKzzDNAXFECDTl3MLP1OaranmK2lk/r+IjXMUl3F
# DATA MyzazjLVRbtSGH4p/NaD6COTArXYkGDjJ0IMINgRXMSMABwXG0j7M3iWEfJ0YBdJNvOT7R8GVZ/Bv+S8AZ/QOTxlAthf7BN43RIJ
# DATA JwgRIepNQPdZZ1S0Jdn80XRBhqbv4qtuiXliLbAML8pCG5wjgWvBAqrPHTcbXzpkqQ6iNcMgD2qUsPTjDWvpp8v5SdMs8/4nhnoR
# DATA 1Fzh6nBQdaxbOg6U65A+24Ze6D8uE+6EruP2Dbu4PBJlos11zCstNof/QbaPV6nE9Ea3cIo87Wvd61mrpzjwdgJqD5G8jZ32qRJw
# DATA XYSM4vBXu5FL1/AY5z6nx+ClkMn1quErxUBABvXLOLEJRptuXQbD/Cvcuaxx14BlzHS7tlh7QOnVWWBrFUSUXM8/QS9bwlAjT+Mp
# DATA JHP6qNGuMvIJFBA64wnGJMa9B4mwpcud72bmHcmOs+2Bw/jqUi7hnQ5Ayehgz7gQIMT5GrzZ6yTWiJiNmabN0RHBZwdfkoEjApiv
# DATA 6A7upUmM8mkHAI0Jn0HxWRMCuZpEnnQgV4mDXYBYXSr03kUaoz8OzFjPwodDHWZD6Ppc/BTeDH7UHvHc1BoKwOdibIxpEURSuOXp
# DATA nVkcrH7L8t0HFjxJ8+rzB20G0XQmhA5HJRKz6QNQ+QhBtuuzUIIE6MCX2eAgyHQO0hkgEimJyuVMXDoadDrS3anbU0+rdD0+KGKu
# DATA woU4X+jof9Sw0eI1Q2GjrNxu4XroZmAp7j/tQZ7FXmuQn/ZHofFbYj6nT/rd8Zk+bqw71eh8ACqm9LDTa6O5jBpdl+kFwdBP81RP
# DATA 3K4x03al0HWit/ZT4AivpItLXE/bukt+jAMuvodrsu4tUamRox8Tl2xEw+A9MdEPUqfuzUNo7E4uCypt0ERfVlPuNySGK0hXZXFk
# DATA aUxSuvKEQg00I9l0owvyT0ITJwchnd0M9ZjmOOU7nHF6jjMzdoQtvfIDDHaa/dbsWNjIskjdRPumkgBOHVSiy4GwFCJ/tbRzW3xt
# DATA R33L2U5JzuVfgu946onZl/KRp8YFERdRadhEdXW7JU8JE8iiM8HPQIkSeBq++HvwN9IpvywSCD0RsXL2WObFVuTz7on/9UshR0iB
# DATA ByE4v0xtOsbKgzM9QS9pfyaCHieiPs7VOXN4nmStYbeDuTE4629ewd9Zqy2K62NM/kCxna0Rx9l3hphlXn11BhE6imS2+09dVJBa
# DATA 6AzvaveX/pi6/aUZmn3T5n+Xiv051pzpAKv27SR4mv2lmF7fBY+QASSs6Hd3Q027cbpl1SPgKK4TekyZVg8c7K0iTm4kthz1e0pg
# DATA 7vo4fLGl4eh19Ydue2x5xS2i6Q/LT4gAI9YSuGd4gW+kWhCIdNp7wBBl8Bpgt0mbvlC4vn7hIGr/lO5dblWY/l05HocJekQccRmG
# DATA CHyv0DBPccPXB6JrugjuwhkSxnvJV+Vt+7ItIFbqV+nez8c7HIKaABaHebpaGOqKqyyKxt7R0vlCRC4VB7lMcdd3/bQ+dTvg8364
# DATA kUpXAl4okPKeFH/Jdc4X+xsCEcwaldTPoBMLdjMqpkXcHDrY7UpAjFNAGD3TnNaGTqE6t7wsnerub7Uj0hfEJnmIBHjLQo446Im+
# DATA 6aXXzp5VDLOW9ZQ0OmwZqJ+Z8UcxWNG3k5uLACa6WJSmOIi/8xMS/4L6qm64eUBQlwH+UpFwIw1CWHdbqZ4wrl89CbEHGeobBgHe
# DATA RPy6erLcv7G8PCnsuBf+oNqkpUKEQ/KGRKIjVRISSxuBJbMcMchEwQkrGue3GLNPug7glOuDF0qS0qdeprNl/GOW4bnAyTSZVDKL
# DATA TX102MheOjpESgUEolIcacPBHCwgS3UJSomasGdVy27zS6SOTg0/jA1nGVdoP+sxjSiEVhhHJP41CTP3FailLbu9YUKfcs7jlgCt
# DATA SQAn+VwLjgTr1BqCIQGTTxAsFhYqyoLRryUbiMQM57n6LEf0LFSpdduMDTSAyAeshA99NI2NanG8qpAlmmUmlHshzioyFNErEYp8
# DATA gchnJzV0Wjl4I8RMm9/QadidV6boiZtPha8m4yhv4B+12pz8Uw6CsNxh8WLdfScIQavDuMvo7eZFYwnOQvp7o9KB/MHdbnHe106O
# DATA AqrM92o2ktA0MTiYZkhhMUtYMBO6MDPv7b0wSIJZPsQXsq71qqoacfY1vTw1b+jr02d8ljtQHoYmUaXM5vA7wRH/z2Gqpc8pxZtj
# DATA zmOfGx5/NG062ESePwmnzJvB0v69UYyIpMl8wSdAf/iY0H9cfZ4fplA8ljUuApRwNhQuqrTjNx2NnWkAtwAyO8aNoiJ9GOWqp/i0
# DATA zwrRkgs5pmrVHnMFUBJw48BkIeEbJG2X5hwXOgyadGb6MYIVv2LYWiU9GEvJQAyhn7IJqa+jVaTbAtGHPADKvi5uetYnZ4gR48RB
# DATA 7fg0EVq62UMc0XZQgEIc22S+pDjc34K4A70VzWMJMxJX+2hdTdhZPxulLetWwJ9LjBgQT36I+/nHwgOBkfQ8hSWqD50WUw1NzNgX
# DATA ybocrfhT0gZDkpAf66zLshxHeL/AmKuzFvtXSzZIUO2AD+SVSYYeoqF1TVY8f2vP3sPgIY5dsp6YWHSbYonsO/R7H/LnHngFOyJy
# DATA XW0ZKuMAuf7RsCVcrvcPJlPSCNXdMx6E7852f0j+CwP1w0ayoR1xe2sHsXZW1X9p2XGWxQL4JFRN6OVqn50ZIM34kcgRGOZh3gD5
# DATA xPGSolANk8quINJDspsvdX4yutWlTkHhQ8NhJq6mw0snHoOtuiQkVSEKFROj1BM6iB02IZaxmMEYxB6LxRCDh0mES0fzjWR59sDV
# DATA XeJXjkdLYqwZa5B4hUyKI1ynxrWWYuSU4iSD5Qa3A3a5NCU+tXzVCEaPFkeiwcPWxb6YFh7uT+yVQ/6jAaVfUsC/Cd03wfz4o6oI
# DATA 7bNz77JK3pFDGekvcAJCzAALFUDoAZOXx2/4Ip5LNExeRCrT34Gizljy/uH5P1USDlaNaiadOLkvIQYb1ijmNwT9nYEbSTCzbzyQ
# DATA 2Ypc6ji0+M2x/VXC0ucMfDbK4IsUt9LT1pOs6rxvb4svhayqvjf0DkOmXSo4PTbafXehYEVobp1imG2N9SvsuZkAEJfY5VNSBU5f
# DATA 0DaiYApL6ugbhv2R4ncoNyQkQNZFUDpikUh+XzJyKEfwA/5gUlz2vuA5kBSCzA08CX9azJeUY2qaEP8nsieiYAIzPT33Y7miwUJ5
# DATA DfEErok+Fbx5EK1QRrhFSgetlZkIlMjIGu6k5I43+uASHdSWNJg43SFykOB5rlh/CdMefQjrGWeGRxUc00+hIZW/vOTYXywuqluV
# DATA ZHHRlDAJU1BVnO3oRByqr0uqrYMuQr2fqpOCOAv41YT15nKkuWVG9btgpe3DzirpO9oOmedPKUETRSvnNYr1PM2ela6vlm3Sa2Sv
# DATA YvHN3hdqiW9v7e69t7Ox29xe3939YGvnLir4qaKKN3T25Ye7Gzug8JeHonl497b7yC/FC8Y+FsdpfWlJX9QvdDMmf2aJdPuw/uba
# DATA 9dWl4tLf3dl6sNfceHC3eXfr/vomuDunp6PRIFdlw1KzM5Jurz/YuGdfM0/8Incf3m5uP7x9b/OOfdlhpMbDbl5yZtXOPGyt/Zt1
# DATA EKbe/2DzrmrZ+u17G6p1G++uP7wHU6O4jHEWduT+xt7O5h071q32WQfdPfQDmLHozEK+br+0DzZuv7+19S1eEM33N9bvYrHRdcEK
# DATA ebVRIZ6YF7PhlN0tSgsuZJIHrdEoG4L0M0z/CgZ+mNUQzieDnQ/Q48O0UVv8WurybRpnnz+vYCvAglm775FRbh58Mj607zMQerOe
# DATA BARGF3bcbZ3kDSxySiIQLP9aAwEpVAkhubqGjyRxgE90XkjwmAdaQANcSXrjs8NM+8jRhRaK+ZEbDYFAshouw8eWhevX00fDRz3A
# DATA yXj9Up53CPBg9Bq3wNGGYXVZ92lPWEbjlRBWAGwFP8iUqC2/jqtX6xwcGVTnwNpQg99gvMqzG2u1wxtrbEzTw6Lj5ygvi+MQHUHR
# DATA 5rLxpH1cdsON+Nn+Y2YY2FeqdScbjrazM9g533062h4fKrr9LYb2Ui0Rj+FSPYErH3kEFfwiA2PJsS2U7INKsnc+CLI00qzIgZXJ
# DATA UxHsRWPVf0zJFDkftI7E/RhCbwBi40O0y3+E6fw+Y/Ushrx9Fk8QwSvz+HXD2DQuaL1NHvVsgxrpBSNgqDX9ul7DIBQxCKo9i+Y7
# DATA rHS9aYqaC7XYLy4YvAocvZNxr/OsvvSkNVzqdg6XjJy7NBz3lrDeWt4HL/C8m6BU1oTjuH/U794ySpJsiHr35ELXPOFnebd5pGa1
# DATA cwwHdJZEahl18yWwoh2dqpbXBtlZ9Msm7PmCrwfDzhP12P1WtzFP9u7tPlmprfLf6/QKHEOrSb/ndAEJb570j49vsXpEreWlcT5c
# DATA yk9bw4wGY+l0dMY9b41HfTSo208yWG1NDOZbW15LltQ/NfFBu63oequtpuAvqncos1AVFml1i84qtXvyXudYbbju09Z5Hny1A/Bt
# DATA w2xY3e6rrXMOm65zNGIjf/XpadarHg37ec53nGK6feKRkr/6r8nSMxgAMKQt6cWA0kK3A1i7Z61nzcN++5x8HJZvmecnw8FRk8zZ
# DATA nbMMkthcX17Ovee54iinPQdeAn8pLmDa0sMm4tKjAjgfq+mG6sWjR7XSO689zbrdKmYYWyqr3iTtrHcOXkq3gk+gs0AhyWCRfG08
# DATA 7OA/S0lDTRS+r/5P7RPedceKrTktxSx9FaMY1qpOvfIVE6lPmEaqur+cVmjbNIzqAw8k2qr4ts+EFihKvdtwXkENK1gDMry9bNRE
# DATA 3oTc2bkmexcJu8UycL8hf0IjZU5LGITuoOCV/UCRrPW79zcfeOCKvyKAeDAAEln9SHqd/grRXISvVwy5wFjpAjf8IMazyPBXfLR3
# DATA +ycnZBK8SNuKfKBmPoVDssqQ0Gl/oJXwF6naEFXYC/DS9WU8oOAWvqpuvZnyQoPoBEyMAzoOTLgFj8c9tdjyaj7qA/QQfMzVq4f8
# DATA K+ARWQsJlTu6R+PowaqxtrRpTIJixt3OWWdE5fT63N6LNO8fQ8tWltduvvnWDdUgRd7a9sZkMpnPVKUkLw3ER13n3aABmDQAJXkT
# DATA 2CnVsN/lg0pMJITpyhv7x+nK6lu1ZfW/lbo+KOu4o+KfcYBRY5/VgFWgHdmI6AtQFKsdJPcCJYeoWV5SvVjiGwUltzPQ8eTNfq8h
# DATA tVftQxxNdSq3UXyHyWZpFgh2d3R6nk4cxRZpJWd/NIk2gx5jnI9qx0itMDADpXfu363uvr9xD7HejgDJrXqc7+IRp0gsEL8uECcY
# DATA upUlKgOdfxAwVI0JtGBlGQVHJtu4qHPSyakTBs1NNwgjaKgk52zY6bdpL+RSQxfSlEBvBlzgQD0jfKT91BAQkYtWwIVFlpYRUesr
# DATA N2tr6ZUXGekeTs/wkGukb66snh2mTmI3NcZ7fwndfLh3B+bRri/dQnt0CTX0lOrmmcDBSbOTwxl7nlQfJl/72oUj6U+Satu5eff2
# DATA JJjM67PmcnV5Ij3n1JosGGvaMbxx6t+otrqDTg/I47x7rWgwoB513ojvkQWDZlarudoqiFuIV6RgBcAEEgzorqK/Z9mZmufqAFkh
# DATA epapbYSbCt8B7oLaBdde0/gPMhj+62qFI5F/66236BFQJPi1XNih4qm1domq4q+wvHyO9gDW7kvOrDBfCrKl3lJD6pAlJGQC5Csk
# DATA WPjX8RMNWZR6MSg1MTvFipniL2Hk9QkePAiU5JFPG5oNAIV+8BjsETeXK8na2vVJoTnoZyi9fzQdf05KkRKXEWRIi8uI8Dk/1IKi
# DATA wzN9lry/t7e9m0atCPm+NI8E1saD+P4N5yhcvcRpNAjSQH27r3kPXHuFds96zOgZObamUGf5vabUwM0dkwOi8zy272JsQjDDwDGs
# DATA RLdt/FC/2uE8ffejsQb2fahaZD7tOAMX0tf5yLb9gbYvIQHotbp8dr9ero1OIRVZ4202n4G79qg0rPUfv7NcXymXa0fokVoqe2+o
# DATA R0X0y6Eyb86iMiurEWZg1WUG+IQA2gNbHBxPvdg5AzBoCaSl1oYhc53TQZAiZ1yUpeoFe4WeFuwKelpftaeZe+i/t3V34/bD96BP
# DATA Z+PuqANi8uho0FgGJoAXXXpzuX4TBK9UUY66+n/xc2ncHkzjAuJMa7A97kArybMM9Jv1JbVGlrDpS+ZRfdg3cPhVGM/6Evxr75HG
# DATA qL4UZvQVlWsH4AtREHoKe8X43sPGZeeCYqGst1QiPY71T5hmxgCo66rt7KJ7E/qmmNmLTDgZw/Yts8huPWIDR+IBnZdwN84twihW
# DATA FgzCGNvQSOHAujrLyaxvw2F7Sc0sxXTdx8qUxaH4Br0sotoTTA/jfaNkzdz5qH+ylI8HMDtogY81OSTa4Ay2BOOgGa9YM5jiFXx9
# DATA 1B9mxrUj9jnMo/vWQZyrQaM3zGFsHR24LpVG5+ISDVaZiuflUGjR6/ZAm/uDnoGuMi+eklE3h71adLYjUAU5xBQRLXxaX6mt3rR0
# DATA K7Y4Fy5HZUjBC/tbkhnSdMLdWnuJETzwJSQ40ynbFYfmsqXO3gGXLPDp06e6wJjKF9rokU9BsuQEXpU+Tl6FE6tVk812Yw38WMPl
# DATA EYlKBi7N83TFHKJe0b4nKzomRtxYaRCZS7qLG1DdFdvRLxhVDOZFY/woUFYRMU3ZOenZOY3Fs/OwueQeW2dxATSAgG4jWoqhlAbV
# DATA bE4VGXvfSr704RC4a98DcKrh+lKCl4zpuQjBvusJqIE9KGfue8A+T9tEBcDXtA4B9LoG/6yVyuVJOWyhHw6sKetUOacc8/+Q/skw
# DATA GWrfOn5yFPpWIUjFClgG+k99VTlrxfvdNlDVp56/FKPTVNwsDFBcWZriOSWt452KIj1wyvnTzkjx5OgKAqvxzz/Yazq+GilixN3d
# DATA pF/ooCBdDOC39hyARCC2yosg4QPBQemrwA2jEvOjgJvWn0tdOe5XrpNg6Fapuk0OYq81YPzIKpydF+c3/J8GV/az579nB0oEa8c4
# DATA AoBqj/hLvvgpxWhByeTU3R/3ZM71I7X4+pDEqLRfOiMnMDCvgfcXX+4ScJS9cVcJa50erkJxd+eDlGNSEFGM3aPvY3UM7GvTkVMr
# DATA cOE0TYvoh106fC1WDXjhKVkaHHA1+hXsHLR29PMarzVuD4AH3nm4u9fc2drCGUHVtTnxVGsFEtkShRyowqFLKWqZbFCiflRJaOkL
# DATA bANsj0iuzL0hyxA9BRd30087vfYeaAz6T7ISf0DFv2GzTY1Oh1lmEVyqAIWFMGJ48HGNZ63z5DAD02fWriUbGEmqXTi5QHwTECIG
# DATA rcNOtzM6J+Gsor0z0DmSGCRFKlD/BPQN49lGfaYUnVwDv9goMZqjl3WIj4aO6aHWlXGWLp/QTI2TgTUJXcfsRnAk2aEvB/vSvClm
# DATA UxcAjoZg5cO1Z+9eP9BQb3BORFxKfQ9lWdX+6oFeP3F4ujnLI3w3bfujolc89muYQa4zBKWi1+0OqOlnzVGfNpQO7pEhZ3CY+h92
# DATA 8uZc34bg28ZvilsFc4sp4/kGunnm6Iy8ig+vBA3olqamsMxlObdXDqCa+Azs64k6COci3MV4ZdatWEVE6AM6ECPvlDmDjMCYliNC
# DATA 2CPYrUpMpu17n/VnwKTcVosVQszh+k5rsN5u86+7w/4AXxp2nih2FkyjB85J7J371nkaUg1HyvI2k6Iz8qDRHtT15AKItnpaVjyX
# DATA EqZx8cHQDYbZceeZKnldHfgc8dLC8MSSF7/0vmLzAkJjHPXVWeO6UsMkQGvowOF2wR972OCVOGoi7u66x0wndUENU3zyA8VZWEXF
# DATA ZH5KIKvAoSyuo3rpOgy668yxUytUUPLiF6NRkyF/YguwicMgQDy+y0CCw3LTAvG0jiIsKFlZUk0jKhRwmBWqluiLobIE4T/EdWXB
# DATA ZGIB4F6LIBwL4vMBhOd3xNCwhfq5i1poi/HLmYZZ6IZEAwiZmpcvkFX8cF4EQ+NgabB4URtYumQUYXn+0HkZCFgMkTSzv4R2LaID
# DATA TQDsr3Q+pC9e/A3yzJ+bJBd480NMsfBTh7SiN1sjkeJ9KY2fObC8pQBXO82eOSjQF1NDWmdoJaAhfB9+liUuqg5qPTZwtxVDpAvw
# DATA bgN3Z4RqIFaOzjqXZ/KmXfL0FvsXI2rgSURIEFC8QrIreBvT74FWaSl1Qft0K+uxZPFnrWcl/UIFxJ0GnztYSx35CjrGncoOymUj
# DATA vlQS4e0VIXD/7O6aYNWI1ebk7EMI+5g/l3r0kSumMXrv9Pg2w+mRtyXOdoB8E6Txe1lgYbpwgIXph1BVuBi9tmBTkF6gtgxR9MRN
# DATA OKTKUjT4qAvOjw80lu9ea7jZO+4DAhUC3/C1pryKYDcP1SwrGah5lo1aYJcp5Vn3uKKzxJVltrkRogqqhrRGqhn8hmpd0+xxUwrh
# DATA KalRWYa1CUXWwA3GUTPpm4AnCRBXi6u48LEaSP2QLOr7sQMU+sgiHbck0ZWjqzakFgZpMG8dZwl6qQnlOH9RK2w55lZTDVmwAwWW
# DATA zuZA7ZuiAcIOheOpX/STUKFlRJE+W7B506v0pDcGOPUvp2JdeFHluWL4AQi5oG72dseXGEKDMJhGUM8AdSUo0tvpOuucDJnSMdeA
# DATA KlrwsLSpB7gmsINkrbOK2QowO02czsaqWSDXOTcbP1hZVv/ZlCi3YWAScnAmVUO3f4KQlrhYGG8ZAIAQ5KmnZHdYOOibCxg/T6DR
# DATA qhmZSYni4rxLKqQ3yREeBo1kmUR/Rb8TvQf7apeX4Ff/8LsN3T0ysAx/QNjsHbVHG/4mVnJYrifAk9Yz9D8BkcN/TDQO2nKtkax4
# DATA OKJD1CORAIxFEE4UiXhheCiU8rYcaNiu4deKKWsdKrZtPMqIM0trtZRgsoajvOi4eNjDjdoLdzXiaJmwRGxGWo6eadSKTk48IYoE
# DATA 8jaDuJgBU7d4cZentMos4l6M4EA5YWu4fCRu30yWRZVM7+wqVgIKrpmiFggyF1A1s5ES9B12m9G2xzYQM2Invtvv9BACdZF0BbFh
# DATA FB/6ygpe6XO0VY8QRYEpCqCWWlvyOAVDxpMXBUsTQxgP9NRzlj0bUGCrZUV1oJJLibiVaTniu2MH4ewxtAl36HL/reVlcIaHIOK8
# DATA QXYOxDJs9h+T9/t8QizRCbUnRaeKpk+naXiJdsBxezoedbq1did/3BznSmzTs1k7BnXpN50Vei25sVZ0/NqR3lS74/i4cwQxHQBh
# DATA 9hiJrGKzzpAs+Rta0v2oKk6fynwc4H6lVoW9oW86uZfMeuaCPKKgGPjyTO1/8IF0C38D0OO64xxfVsQZNxADBKo1PCaTkt77AiRQ
# DATA HyBkHnMxKIH+U5MrzsziWZA+O0yRuPfHo8F4VJ+6GI9O1QIo4fyLPWGAMVdWVkhziLib4WIkPTXJLkVLD1t8ClBd5u34fjvsQtiW
# DATA UI622qWzDigk+bNKcuPNN6/fiATVC3qDpdQLzYCFM/lUjdhoOO7BbLTTeBU0ojXGAIWK4u/ZYakSLH/Bu1zesVofpxG0xH5eO87P
# DATA e0cl/Z4axF6/5KId4QlmrImD8xjXI9Qletk4tFf9JrcAUhSgOxYoJ8136GaAaIO0UUA+rKGLILsPsN8eGYm1E982rkcoHCxFbdWL
# DATA hny6ub2B97Ph0L/P3E/nDMNhwALTAi1qbQ/ulFbAA1a//rjT7YrXa+1WRjEtQLbEfRR9dewlRL3JnPZOFOrIR9ecwk/qVlD3KoEI
# DATA 6SNIwr6EJTgeelRGN4kfLng4FKarJQlHLuuuHXUBiFJkMe+0Tnp9tdWPMKeafVlVRZsL0+H5GLUVakqu2EfK/ZdGa4RC/BqN/4h+
# DATA 72mrMyqxX2ZjVdAPppXg43anP+62GTFPsVjIKgOxQB5P9gHRUphOO0+kFEjD6Oe1R76NqozF5t6RaRUoRje90+qh0KEOne45bixx
# DATA 9tyyWR/sFtF4uJAXnfBkoaRQWjIL/Y7OS7RNN3inmITWaUX2UmMTqkq7crHi4j6CEGe5NsgVEasZ9GHVxM+2gpUlHwVzSKRGJ1GS
# DATA 2lnKIKloqNzO6rJChAlfahTQKBvmN2dqtjeS9YRD1PSyOGs9VvIiHZgQGwem1S6xbodq3MAZGJfD98aKXQLA5KwzAGsxl3fUP80Q
# DATA fEb3rZbo5EXJ4ywb5G6+DzvzhBWsyHB/DEBAdFh3evlAA9OoMShJ4srPUpEulJWTBwBdi27ZxIQpdlf1OGvSCcA3AStA//Q2l22U
# DATA E0NvGsPEoixSTHj6xc12WnZSReqWgdjhvbvr543eGfd6yANFUNUp6cavEk6f+ylnNgZU8Zg27wtHLc7ZGiQgJCKpk87vR0VBmDMT
# DATA brKSWbyM2l6bXxIug8RqeDOaT01itV45nRoW75l6LpcWyRvjj6fpS4W6PSITGClA+F7Mk7vO5TOShpcHrTIzpx3v6anGeavZhsFn
# DATA hWyBFZnKOyjKNFOQxxyhDX8yx/BZPU4wiCKbCgxTmzEjBdF09lnAo7laeCihRnQQju26J23cJSKTW5G516acREqiAoFi3AFIeEUH
# DATA k9ZhDtSum520MDRfA7XYwuxyxgONWKsliDaDw1T9RCmNWZa8ljwACPUkf4qma6SWXcRWqfny1pRT35ihsKPEaWAslLMenMeFNoN/
# DATA IVDnX9G+IKO+tEF9Fp1cnb+BIE4o09ev8UEUWY+w8pyUuXJNRDV4PuT7vtZHLvIaGp50+4eldDEteysWdHmcJ6jWpVQGMaT4gGTB
# DATA uJlcYMbK6SYHK08bSLaqaKwRyLDzMSYE5gy/nz3/NwNGDLa/T8Jx/Sy2aaaoFI1WAzptclgUJJZfLtIwovpWmgKEorewwz8vXBJ6
# DATA RXzy4scv/g6GAKLkYnZeXGO4KNA30CXI3gBghzxZPJgsPQpTpfMjSvbXg/QNpRiNnUK9EZvOIdPoFTHLfF+WCIA48EPOUYO/TAZF
# DATA Sn8VydXhJDGKfePsGeLpQJaCjYOvsU8t8SCgXOn0x3ladm4PKWfbebCjkDVkWFFdsjSg0/O4jpiezelpQi9jOgBAhMQrbjLkTEHL
# DATA q6u065xwehvxLqUmibzNTfJzAmnW4sbaBAUKKHL6Ro8m9WG6h5ihYEjVYMCKvP6BnKQw6RoTVp17S+2eX8GtsKnOYMAigxgGjP1f
# DATA Uo+Wng1b5wyKqyeFuo95YAjE9nDca3cBUWJuRx9Z6WuzVzaCvtGIFQ7YP3q9/lT3mRKPMbf6mQZdpSxl8hDivOGcq8xh4zBfmZdz
# DATA wE9tF0lB/gWdRxikiwBdnBvLb2B8/egNyCtFkFm1KZz8rc57xP1OHarIacwgtJ/oDnkHtEyt+QvKAqYeMHkVidr0Glswfn+5yTqc
# DATA QgiKyNiynqC6TbFhyHAosbgj9c7geJcM+k9BrOvnOSR0w3QarSFZHXrZU1EYyQDChShBkLD8FDmap6eAN6ulSW0ZbPXOE1atYAZU
# DATA obChUjqUfUBg9wBnq3gDPL8dvgGZdssrBMeGcOGQn7HPuajQcdpAjDpy2sCf7AkKqglIu5M1Ip4a7YxCH1CJpYYfVX+c+SSvbTV3
# DATA 7m49uPed5Ad0pRlzc+PB1rtb9+5tfeAuyVGMthqtqK3S/SrQkYgvSWUlvyR1Bqp0m0qQV8Jxic8UhnKvB4LiSzm7F6TZDVPt+d+c
# DATA tRjfON3RBSf/3w//CfkMne9BQjUnMimmRhvUkaCoqc0080jHqoEvL3YBqxFkY8nz79bshI9m22Rwon0fE49QEEkoFEdg2UPHhccV
# DATA jC5kJg9u+ESLVutCLBGRHlzKp1sY65/XWm0KkaQNYjeRsDx7WT0hH4jNDubmPrVxtZZ61heKa419ybhPSiREYkCTr1YW5q75A842
# DATA +tC9+EinAcL146bLev6/pqRksemDZEIxL8wMo3NQpNSI/gCavrifJvh1QJBkM0yy5YNYqeo4+NgcTr8lv0eAI/+hTrOMflnTKyMy
# DATA Zga0fOBkYDH37djTeF4DU0ciAxlAXPFSgf4hTC776S1CyqC0zz/hgwjmSwuBXt4VxlqvsZFE1A4jgB/iDv4Q+/1jyE8iTrZa8vyf
# DATA CHkMT0n11h8w38IPSZ+jsTw+Lsj3ogh4nlS7rRAelhw3/01nbVaV6xQxNQQwNpkPP3SSp2CoEwJ/sEP8J7icKDWLdrd7/lktrDCl
# DATA tSjzIPI3mAeRC4WhxRVqVyardAy6QghO+/x/YG4l8EKFHDiuNy1mgFFFhgVSbHlYGjTyU1qWvmeuWpxhOcPsREkzIB7EO027FYpQ
# DATA omM9OWpHN526mZB2WAPnJwOMGEBTItN62FrjXGfxwQDO+MY/iEQmWHCGSgTIxOBXVDVwcm30bGSSG1C4dUVHRlcomLnCo1hhWQ1+
# DATA QEyyG8XgEjc3KbRLtHF3SHh6NDpGxkuXUzauZQNiupjfYJv8rPyYpUI9iU3jGM+C6LjRImH2VSc6ldvPIWcbpUYhBhw3+Lub9zZ2
# DATA YYQDZlekdAtTTwrjh58xT3eZbLE8Gu6xYiqFeVLsADrvlHDQy4xHzGcZIoROP3Ne/LgCVOdvbG66zxInX3yMkKepXZl2DePypChk
# DATA DT3jGHyOCLY82HDgDm5LUR3wdQUY2wRfCxFGGwPtAzP5nmEQq8mGqK1FvQR94olMOFTXdI4y3RKaRVuEw9YVRSirvY4+zj9EvCY3
# DATA obleFMjMFJRbdie5XFQPHqf6LE9cBH2DzG3rMEEE9jyncNIDnw+b3bpinigcUBiOf3VXERxpc48E45p4WjbMxeF3TpLD+wVORUhB
# DATA TrJZLf45Hc+45v9bBHarzozMSTbXmpi+LgS+lzcwQQXzLg5/gQRVRNYKVeZxfHan8w627Fpwdi4FcfPqaK6xUMu7urxfv77qniwz
# DATA 93CgBeL5j25nnmBaEeOeDvdtp7MKFQsg6Mclpnue9R6fVlrpsTLn2uq214WbXHRRQF0tIe8qebh/Iw2Wf1b8KCFN1A9RO4VdS/Cj
# DATA T0Ue8IB90rV8Myzx7SWyWTHMU3VxidloWKfASHu8ZUHu8Qpoo4zujr4CKHSRyPLTqFYubCwwQjwev56DHyV0Ml79WoifxnimFRMh
# DATA b4b9Y6rESQtroqochOKQzf25EDg+ZQnmE9U2TLSYQMcpbTmLECiJ2FFigVCb6HUCRWPz8bR3ik3QobQv/kbLQmxaR7Wh4VNEJgDm
# DATA YTStiHMvlB3ccC+kykF4JN616I89RF/QE/xdWx+ejKGqbXxiNEFqxzaaTcWDN5tl8SWI6M0Wf1JK+4NsqMOkjk77oBcBdFXOtstZ
# DATA vyjfIAK4AFdTZQYbzf3yt0kghpEBKWPmtIYaXw5zG8DvE0KYI4qVIvpxflrlrOOUFLtzfC5uOHQIcFqCm4xvGdzn9gGUU2ekUXSo
# DATA csx3LG9pOLwqgxZgj7utnnBswPJZ/end1t5S0g1iyN42piQaQKioyg2QY1PwmBsff6j7QU+dviOavpkdC9OAgg4qBrWHQnRtVKts
# DATA NCvfKnqBbXDFL2i/oKnVWElPLkKPgy6uw0+zW/Caycpc3FhKVlb4nKa6+HkkGW3Bm5gNbkpJQ/Y6gtDL4UneAFX41L6ptTWtYZTU
# DATA y85G4ZtCg2Rmf1rFdqdwMGAjndFSXKbqs6pO4dNCW1gjpfTjmP5nepUI9NV/qTKIWritLhwThh42ryIA+vR9EyFXc46P8yktyPla
# DATA 6bJqQZNXlmfuDqTddv+ZNJGoY2AsZFMiPZ09UZcaacCrLn4Klhorx7CHN7+Lf+Dt3IbCw1XNHHBoYGWqV3dVDtpKgmw0fkUZ7SuJ
# DATA uEMxpSKjcqR4n87WvTBazarLEn1URUqu68fc+k3bd/DfhOia9VqHXZTxIWPQfMAYCL9hMSDUlK/fu+cCZjh2EA0gjxw16picxwOL
# DATA /4FOusZtXc4LIGfBkFF7U6PH4PZHYWWdmGOnEQa6zPaiIBUkfNYGRAxEv4feTetlmyBNODB9vtEEC20MVN9quMT0G5uc6zpvJtEZ
# DATA O9bBnasVQakL6S3C1+v10+mLU/JYdnjpRhMeZuSvXbNQAVPL8zmjSy12RjEoQsPgg6qpuAL6nm+UK0msiXMOrXhFe6dBA6Z3M8bt
# DATA CUefiNP4JYnGVL5RyA/8mvQ016+53b7MJHp8sZxDeNDkB4L0cPnxyviaKXXFbPXpjfBZcakspRPdacZl1meEZ/bXvjapFi0suVQp
# DATA uQZGwXNx4Ww7p4Y8R7g64wnGIDqkDqp4ali7/u1n1lfd/ZR6H0GXtw1BhrMc2VjMGjbtBrMfCWaw6SzlwNlzWtcqyaweeO5r5MLX
# DATA 6Q3GIwf1AQ3qdWtLAFGMXMfqjhsPPpxEtz3Fc9hNP4UqoAezQOwuWmbTZDfbL/3WXCtori07tTrevfMtV7FS59qmhZJmuG+pAQ6m
# DATA Kb4qmoGTURFbkNs1w1yliivNGChXiyDmAu836f6lSIrRi9SnrR79VmnWKSZQhKNkVKcch8U9o6+B6mJ6C/ntJr89raUhDcEL/nJG
# DATA s6zyyOcOMGkwoojoV2JL87IjyJDxfpsN14mXxDCVzMoP0Hyn0gafqXBcfcVWuhUH2QXGXHX8VtyvBHhSoxwX1Urgw4MoyyOchmcc
# DATA i0aFN3WJ2PzN03am4ccIJ5ouCAM0HFsQhGesl1Bwrvvcr1GVhtjN8SqdJpYv0wCtU5yzDTrFzqtuxsy5cuqaOWWGeM4hy86s2mT2
# DATA LfYgpOglSr2NPt5imczTBgYNt3Mwi2HrnGFiofzcxtGq3zVyjugpJnpUWhZAv02kr82m2GMcCVcOyiTeuzNy5NnSYImw8KdY7oQz
# DATA +jwIehBEiDluKUtRGGNiGqLzEeJFaVDR2RScxWY+s02lkC4XEeOWeG5CN9580yeH6h3HicbJjBvWWzS5ZCQIzwVNUCn151wHpQH1
# DATA l4fAVMJECPR8lAmk+2Tq5o1kc4o8kNW4yfgqqOKwlfb69lnZB6x/mZPBLWIDgIG2IWSOQO9nFDPH6XframePNgc5jGqAFh8c+nOz
# DATA A1qpZFTDVYSvduL9tRuTcQJEzx9OCgaePp9Nh8kNMB/NvpwlIaT1QAvG6VBimzZ4V+ZPcT6IJk7RX8FirFPyNkt1w7doA9XdVK7y
# DATA UTmmwasnnYEa4SFExXcGhpvUjyucHVlG2hYNEqL3Lfje1IHaUxftADkK/2pObQ+o3CEUd5FftX+oq/3xhLSfT0C6JV9rgYDhZDay
# DATA JQif7GIRCi2e9Znc40JBLgmtA697ipaUTAV1QQEn4ZSxWUmiSdRjeSH4vfWAcxWFzOZCFxZUvU1cSs0mdr/ZhEXabPIAOMEQZOSW
# DATA ieRDEAvAGkEMivq0w17v8X998Xdq8/6CHIoLPCZmutdidYq+YLIpYCMoQFdAhCDgxu55PsrONijHm+xE6duwKrD1leRb2Tn/gpwI
# DATA /HNrl38gusGf7249uIvwJXi3LAN9NlElgsj8nd5Rd9zW6FEIt5/Xkx5GK2P/lQj+XQJroAAHjHUad7sJVFD7koevljz/mQ2DevET
# DATA gjrg0HPjjV1x0Q9+TGFkgi6TY7abk+LFjwGl51Kz8Z/+9N+/4/8UsTjsAgOgqEFtcP6l1AHx0jfW1vCv+s//u3zj+nXzG++vrCyv
# DATA rP2nZPmrGIAx+F6r6v+Dzv/rr78O9EAReTKa6qgwjMLSKUpIZ9cBOLlh1s1aOQDgUPDhSm219o3V2sLC3im4d8oXvzdWckIyOlXH
# DATA HQKNcewAwkN2TiDjyWnWHWCIwilQQYCwU0/745PTBXxJ8RTtVhcwl/bubFcJX/M4awF+DRosIXzStpEzKienrSeZal0GTsdgH2zX
# DATA VNuyIUZmthVncAgcAWAw9frG6HskzzoE83yWHY0pJhwwlYAxJny7BcBYnXWyBmQw3ZvVn1N1tspGp18R4XRCN46+m/8R9v9bN95c
# DATA 8ff/6vL1P+3/r+K/dJxnLCektxYW1EbIR8lFsj3s5GetO90OSv10lUzQ1x23dSn9swHeXDrCd9LyLf72u09H8jXgqp5mh2ShKJsa
# DATA du9sbWOOiC3MR4QYn9/PSvuU3yHHnVPXSNG+V2FeBzgwxWPrtKycFiJwl+bneZ09HotfAIlFFXMALTwe9wi0YZiNczgdS8P+0zJn
# DATA s9Cp1/pPk//8n+FPjZN9OGG0siJ0iE7V21YNBJ9lzwZqgNZH+GkPWMMf/CBxHryNidjuguRRLgff50dKtslriq6eIOJBg8dU3/nB
# DATA DxzRYq5vriUrulf8KjO6uRvUgONZdhvFJQELfF7Cr5PG29Gi8LqsRnqysNCCwOvEjLiSdp90QKQq0eqqYBYGndFKzwEo/V5b+qv9
# DATA 5eo3WtXjg4ubk6r5vTaprpmL6+rBzW+0Dg+cO/r3yurka0s1yFWNyfpg/CFVgRg4QNDvH+t8Wq+hangEKQlSeJlu67H7ZnJ9tQzI
# DATA kmplwLwx7N9mD/UP+pyiA0Z911abptOC5Bq3NM6aWje0lqavJPm+9g0D4RBw9RIatlpr0MF8hHkN0JAe9jrfGyvxNXkK52BdbW/s
# DATA 7ySZcOVLS8lOlo9V3ZgvJmnhgV1F0VKjMVW0CwRUh2v0HA9hQB/oYLCYamGrCyH9/SM+R4+TYefkdJTXzLSZBqtl9prZX/puWc8w
# DATA Dr4/lOxulSAtSY5OW72TrH1LGzuRG1DrZ0Ril4zFJYdQ6ipl1+iq6YTSG3YE1YQWDCGi7MLwYX5p0UJamzBnlUTv2rrdtPBPrdd/
# DATA WgKH8pXlZDG5fuNN9e/NG2t4zgGcDG6NerJfq9VoA3EshzM3e8BC9bvt5GTYUt0hMfOoP1Q9H/QBUx/SuQH+1hjyoo8Q/7dtcLpq
# DATA am6BpdCl9SkPXQtWT+vIwHUhJqkzycCDdXCdjmiqsY/MBsUmVP+ei3iIcaSZKBh9rXuhtXsBYz6p4Exc8OiJwZtMnGlmYq2OpBpw
# DATA nKULnjJ15g0pJzsQXoDD6EI8y/r2pght6LTUZN4Hq8Vxt98fIgGlpdBexzwngB2LuQZXcDLNh6o5BRT+neQCsM5aoEuvAzhwNknU
# DATA glIvBjXpj8OKJuVkUhFui0CEKmpPt7onfbVhT89UT97fBb8MXENTiOy7/eEmkaUouQWwyF4bdaeS8gY39YY66rY6Z/ktCXurmkV3
# DATA AT1SzQLZ/m0RtqoL03zYDtyBA9UBtRWOAHpIFbW0mKwn7c7xMaFqonYf0RMVyXmsVrwlq5AEJFdkDPaiXsK1ZHEpmTiWI26bWrr0
# DATA Cw3UdJbDWoAHfATwc6SbDXkOiBMQ99erPJVEpc5+sfR/6s6RpF9TfiirLntjdowcF4fxKZsULsHhLMoxZ7QtbRLuxBnnO65WagCy
# DATA jzXKVIWpiNpjNTWKSGsY2Nbw5Aml+WsAarQeHxoXKh0guNS+UWzIhbsoIyPZJ84SMJwx/XGJeN53alTUt0nT+06N2N13avmgC3Jd
# DATA LQXk0+SddyCRzNuN5C3Y44GKW3GxgxGkyoP1WDK8MYK6tAaDJTQhUBfzJc1Y80fVwUlarlFrtk/KpYtopKXqRI9QrXZxYdbNOKmD
# DATA sCbT41Ygt1I9Wa3MKGePgGDvd7qKN64r0tNcBvjOTrubeY+u06OgvAlQJcrhTT1XtZeKmlWu5RkgTG63hi21pCiOlvJ/l2F4Uwzg
# DATA OgKa5tYEFBQSy6jVrriBSHw7Vi3lmRLPtVyqmsa4aEE+B3KXHXcUw9MBMtP5PjE6wCIBK0LkLXGyEYcbolzie9MIsRwna8zffXh7
# DATA 987O5vbe5taD5t7WtzYeNB8+3Lzrvg4JlsngXwmAtqcUt7PxUDUZC7UK3RpwFCXiuNQ+8hDCyfZATzlmTnyKQ6o3IG4zRV1rGQ1l
# DATA EZTm89/ALQTuAlu8CX7+WwF3gAbC32FCPBtOHIRGx7Xg//D8n9DGGAcF84EsahgPocfuWWd0BxT+jWRFHUuipwwQxX1lQvw1dETD
# DATA 7VQiaYd2OBztfUptc2GXQCW2GipaTp7cWvgK9D9Nu/tfqSp4uv5n5c0ba77+9/rqW3/S/3xV+t9t5KPs3GtvWcwuAGpWtW9RogjU
# DATA J46UlbWVBIYpqNiqBZTyxpq+AkWQ/t3PFxD/F3yCup1DbQYDrwj9yjDTv8CcaX4bGHh9Z5SdDUC+owLHQ3UkHVI4ki4VHEjgsF4w
# DATA RVPWUY7uJdcs9IpFz2XS4B6350Gd0yBz9vrB7Xtbd75Vtlm1AFyuTSm12hAuyqlUKK+WsKMSCi9C0QEGLz33EnQIKCp4qbbb3Nzd
# DATA 2XivJHFcHWBXnb0O0jLE8hRY42gp3Xzw7fV7m3f5VIHwaBf6xENAJMQbXRGwxQykfLGMQ6UO8EzdLZUnUaTZ5bfeKs9qkW1J8z6c
# DATA Vrc3mts7m99e39tw4JDxaOIBtWko3vTTUBjHuwXHIZxmHv91sqDgHV4i0Zed9ALCBQKfousFTkXXfBBOxIxJ0DjqtFxrgZshN1ov
# DATA Y/IfImRHLfsbn53C5to3dYspDIwxvrkH+ho6sbq8dhPTpj16hCk15LsQ9NYftktHZdCHXYdbfKm49JXVtyjaS35Vnmc4ttcfbNwj
# DATA bmqBsnRTVnuRcAUDsrghIBG0xqN+xNFDDyZBdvi4IShR+rA/MgMCj2bpYnGRnS10lCBGRqD3hhMZOAl2ri2Ox/oKKRDio6Uoz/o9
# DATA PVYP1r+9vnlv/bazjXnccgpylLVyovHdbDTi5OKmfn5k0gD7pRlwaCQPEiXMVKdTYjOJKGFOZ0T+GHbaGGKb9tREKu5RIj9jHaQQ
# DATA 9VvbOsvImRUgy2FXQ3ZZf6R1+2KZE9L99epftqrfByRj+7NZqx4o+qUW6iQlxd6lBv3Bxt4HWzvfKhh8uzyT9HQ0GtSXlnQWbZsN
# DATA CZDgeImi05i+kA56ZjB4goDf397aQfdeCo42rp/SU0rUb34Ccj62Q+5jCmiEJubcRv0Iy1LnqSpCn6qWNOhtqJ7UUHKT860KQ6AJ
# DATA KDQ1ZAZehaWAY6DuwbXWzelrDSCnr783zigbBlwcD1snyHyYl9WRa2pF4FSqDR/C4a9ow/JVSI7bsdcaui8mcpZX27Sy39/b297l
# DATA knc2/svDzZ2Nu6lz6hid7dAu64ouWlH67Z2t2xtAxhSbRXoLnTZUCRPr49Fpf8gyaT1JbyuBWpEZRAzyxb8P1r+90Vzf3qSTRokX
# DATA 6EgdfcuMBKPUfQAodWYFk2KKW7Gf/kVVSS9PW8N21oZf6LaWqv1UW1b/W0lvxd/cHvYVtT5IzKiCtORpLWGpI4MG9VHfW4c4oyih
# DATA r8PvO4Ro04Xo4IrJ9pWTBhVCzElAw+9q+C+8dxO0qkoi16ohVq2hcj3PjH7tOAPCMWOMGFVUkU/uKGAck790PUXRVy1K0EW3unVq
# DATA Bl2QFg4NW7riWv+xtifx+qHYkdYRNID0CqB2BSavsQzQAePe47yxfwAPgAxTs0vUHXyKFhld/GG/fa4GEz6/1sDHbMq61Tkuwd23
# DATA 1xYxqwH8U75wBu1WpF26YNWyCbWlNoA0dLfHoLCtAX9ewvtKGJ6YYUb3uAZ6xVGuU35dPT1SfDAVVK6N+qTXQm5OMXN2uMhX9Qc/
# DATA 0JpavH6t0Uj7aFlGSx29VDNT6r1tHojPokMvurhg9qxbhHow0YDRycVRV+1BvfhwPULfJwslXNylcuNts5i1sbtB04aUfak16CyR
# DATA MXzJGMPLt1THS9x+fVe7okIPWDVdjnTAYDjc0tWyATystchULr5VxeeN9eGwdV7r5PiXI8jz8jvasM5/a/xXfasa/5r7EZRTjjVX
# DATA Vqk+g/f2lw/eIY343C1eSq9hCGP2cGfzjg5l0IWxdl0RnHKpbFRWal58fZXQJZFPpgDEMhC2HwNildFOwVufk+slYRL/iu5GNVN4
# DATA OFQglzyiYAEMP+X2IF2YrQDBeiUsoM1Qb3Vfash8tVVj5RZQGfRfQpFBvXCYlTiOwsoBLMDwoaPoCoUoV7SDFbNExRJUKGRwHVLC
# DATA wFvTDsvt9fc2mpv34d+Qn6KE1Sz61/YyEOxbw/O7OjClRKAQkHJQZ8fCFYFdrpIIftzvKgLtwGjr0CZ6VOaQaa0Sg2gs22BmzEgF
# DATA iijHaeQ8aEj2iXSkkfMX33LUqDGWvcQz4SQTuQrjHqDgoy0sUnixLELiv89l80/B+tOLXLbNBxfLsIGLy2a1O0Dom+wIk4JCJFyV
# DATA 0YbRLbz3pGxW5j4UeaCRquB1+BdZJQ/XI4gcwJrBcbGHbIToiRJo1MQOS6YjVlopz9d4hjSuVgm7rVodKOkDRZ2Msd0kfhO1ohhG
# DATA s2gM8L6aUFxgqR0E3nLRsdC+8cb1XTrJi0yLu+an7wxftGVh1a/fubOxu9t8V+1YYG8p0xfK6UR2QE9okUYQkL+I+HCNimTt0Fmr
# DATA vlf0OGubtPd6TEj7eCvJT1tD8v5IKCuBokDnIpMiUD/heE95WUCCWLD51uIQQJzHyIX8Yed+xXzHNn9aFz1LI/tevYAdnizoBANQ
# DATA lm0UkBxMLpOXdAQYNUNCduK33G+CHdK4ENGC+qNTwGAuKMdNs8KyfCXBj2wmBzkwNSgJILC1kP+aSc2nx8oBq8BWMHAVQXtcpDhV
# DATA ajAuJpMFkw4cOlT3UuHtp0IQRoHhYnFRk2Idry9lZc5+pvNHmE9B07C4SNM3iQjLYui0b7BbMEFZXKToMKWarhd0Cn1X1/BnUkmC
# DATA ZVPhNWOPSl9uVPdkq/l5k/IUzd6C6rzUeoj7EPr78MHuw21QDxhZM9QEQXIOCe6knxLpNx9hfF9M2VOx6K/6U7kswgAxysABRwNx
# DATA z9RT0OqgplBvf8RXtAc4ABI6Wh5okNQzmUNJ1Kgf7kPYmq7ZHlZ032nAaw2P/sw53He2Hrx7b/POXmSY5ehiZN6FOttGoOjoqrVC
# DATA mVep+rr+Rox7azRqAfUCuIZwZSC0bsqlezkvxTjoQngI3J7ph2E7J9MC70TDwIG2BCWjoKe+zUv7i7ZOGORyOdjNpgsY3sZvOw4j
# DATA CAVD9OHASa2DBL+ETyraB5AjHesLLvUyi5OypPDKFLRFzQUkRUN7Ve3wxhpbDvC7/ZQiHSB/jmdRINBo8j5EpRl/QDThoIBXpDZB
# DATA nRX9Ae7tg6A4zsL3lfn/cxTrKw8Dmm7/XV1de2vNs/+urv3J//8rs//unveOlOzdA2MhBKeQp43reUxJqmEPtWQqA3LBs3jLyF8h
# DATA w4cJJJ6NhHWX73AqPG2MPT7qjbr6AmDw1Bf60kQ3v1IbMgj8V7EWf2vjO6Cg3H14u7n98LYi9M27W/fXNx+kC+u7u5vvPbi/8WAP
# DATA Ix+QEYF8BMP0r0rv1MndYz95NDq4Vn4n+BwfLDZqi1+DRM1Z7T5Y9I66rTxP7uJ2pKPGnjoGiVqNCxHEXn94Bs5ITLEKbX18+Eox
# DATA nEgjW/no6+Tt5M2VVfKrZKcsSPv4KH/06OvvvPHo2fJy9dGzleNHz946PkiZhAVWPNn0lDraZNU6H4+eGYFptLBH0J3QGCHivAuV
# DATA 8nPaEhhUhMwFIKJUkrW161HzxOU7CF9SD00hNdJDldJOu9dKzXlSrnUhPyCbph3p3Anw558lKM6JcraLQ+C0wPoIj+15Ww8qAVgT
# DATA WBdYfd9Ea25aMwmVsX/qFvxVHWtT+hpwiYRUVJh50/5Cg5+XfgZU1N1uycsvqnbM8jPtDXvtB/BL7RvIbN8ajsosSgxNC4QjZlA6
# DATA on2ENeyz3U/VxD/R6ndjZaKflN+Zq74rrHpOIqdtVfv16sqBXsaUUUgPJFqucPXrZ3peutpVBaZlbZmmpZZq4QquSQS0yWmc/i9x
# DATA x9erf6k6W2v+1+rBNXVryb9XXqRhh7xBl+8pM3C4SsgoIhxutEvNgIJGHL5N5tnDyiU1i+TR01mnDYIKEAK4M0+blXS0/i6I7Hvv
# DATA p5Ht9yrcgHiPApDMg/7o3f641/a2KnjX8EjUYw6sxsnB9OVL9S8qXd7BaHl1jXNgy6c9gGKC2VgJM2faty7vO7S6GhXM5ptfTPHV
# DATA GrV8nyHRhWvJSlluNni97HbzamuL5xPKU5vhzzyOCDZHF/SH5Jnibgftq1IzAc9AWB+nM7zVPtjRi/LOzsb63qwVW5GZv2Prq3Wt
# DATA YH1F3NIKF5tZSi83i4EaG3lJiKE5esx1Vvge9K258Requ+L6we1AJXobvu30Tja3vC1a0L6H23fX9zaatx/ufsfRdOpPzjtZt810
# DATA j2dbzq32SkLoEXBJyku4GKc6JpmlKXKR2xQOBIBNuhKEBrcvFSQhKh72B1t7zfvrD9bfM6ojoy+ckmVWkmubxzig2faRQ7htDc47
# DATA cWi3y6wY4L8wSW0MFpJmA3GuxDsuBNiCJI9SwQQFM+aR5jpWkm82kHTgwzJcrdwoYk+8sphBh8M7wrjQAY2OSiuVldWbxlHJ9bzC
# DATA amMVisq4v0VN58fY+JtXXC86M/CFnVadYKpOjED4QLAFCIs3WbDwdFjWxKYYxiZSKjBsrGR/kWzK4ukd/xAw7MgUwmIQ1cVGxUMh
# DATA MKlIS8rDXicGJDR9DO9s3d/e2vXUthHKEkp30STL5ai675LVW3YIpnMfBgv0dXiMuUNkH9L1gm9KMIszmmEgannBHuESj2WX5/di
# DATA BkUvr1qYrTqWWxr3wf5BrCrHa5bLiWKd+TXtmwu3XBgUQgFB97sgubAsK7KeS/jtPgFzH3jqXnzmpLrGO6GVh+ZUV3Ggd4S+4TBC
# DATA lBRZcULXV69GDzQDZAEkmXryYPIq0pZC1QaU9mmzGbUG7txO7gGo+cwyUk0cf9RNWyUNBkaicRc9Zzylbtk5wLiQ4lo0VB6/uK/k
# DATA OfAqYSmxoajZSnl/5cBxPtdYePt1EP7AU/F19d7r6etiHX1v3EfWgF5clhlG2vo2dqSEb1Y0y0ra9U7XfArvK4a2bprArtIQrbjM
# DATA 6pVUkhV49s0ExcoSlqTFSLiQmWrTN9Ly3ITFFQ7lyFEzV+qq3oOIwkK/BsooHFR1DqIu7Q2tfMKIRnzWWCnj4Iuxlk5avKx00ojS
# DATA rGVoPV2wBXY50p4Jj64Dd37DNaoNoRVew4UmCZFkWAtH2qMq2MFh+0hg0UkZndr5KLPl1cgeGSDmTifYJFNCsl/hVB8zwE6h58Kv
# DATA xDXNhjUdJ6B9RQU01FmPuknocaB39tUXB9ZTSSZzcc53/ZWvRF245LHOS1FXRtpE1Gsw53ySoT6Qddw1zpZQXoivC85t6iwPURsV
# DATA p8ERTE4GrWAExInDFHS1oDEteXXi8qhREUQPNEXVsJREFw7Ts06eo7+Ps5kuUuysYuG400pQodBFdYtbdpo90xXoDHv0fqc90fvQ
# DATA 2h04bIUwPRoYAsBIWiAJsayBgpOVFqyMGgrNjqxSsLs5rMCIZDYvCSGbNS5BKCT9pE6Ee18MINUQ6FwkM4eFCHN1no34JopJegrQ
# DATA SWqAkCc7eg4mMW0Lfbsfvn0AxVGD9u08HszPMb6//uC9jRhhtztKV05tpmxO3r1w9Tns7lm/Dbhybcv/X5mcTiOlhtF32NmFIseY
# DATA KcTxilytaKz+OrqQZnK6lyLSPis8jRbH6LGWHQtY6uKmF5+UxX2pDfqDkqreDxUKuOaot19YHh4Umg8pfN9kMPMdkKiQ4Dv2KUCB
# DATA sT0+G+TG5S3r5eBM1MqPOh1SfFcwIXJv1FjVqWfncFvkCpCYw/gfpmngoBA7SHEPvOZKEsS9GEZPsMps/4PKCqaxcPVxA2Vh40MM
# DATA ysHSgrmnXe+9DstMDUnDGP7464VpK8nQkSt1iNsNf0wYDrjk8tSoP0GjYrMGblxQhDmRXyOJOaxU0zYjOzvf+RK/fnueg8Vk2NIK
# DATA RZ0Dm/WDSoaMpdyoQsfATI7O8WulMpzmTkOoHFdzR/deTqXL5VJ2BFARN5b7bwHsCGWEyEkjVOBYY/NcnbV6nWPgQjgDlvUw3Hea
# DATA F01qpRMW4U2bEJpTZmHqP6kHiZ5bnh+vTZTlcWKioLJkmeaqZBIw7Njaijnmst74DMFOS3rR2KE78DJ0jdAFWig+Qu26raBkD91y
# DATA vKIIyyqWT8wEiDML60j0O75BL8OLiEoLxrOgjvjKKsXXBAOUc+mBRmFheul2MGd/yVOls7K5ekttxGjl2Qb+hDjAYA716hiCG3qu
# DATA +GYu87JTRahMgnLVi3gFb+SnH/Royx33SNW/cPmDPTa2c0+ONa4KomrEgEVHXvg/A9nc8f8765wwvt8rdQGc4f/31tr1VR//ZWX1
# DATA T/jfX8l/b7y2NM6HS4ed3hIETQzOR6f93nWIEtsaQMbyZDxQa6KdQehoq2fhMgNcUgc6ErA4Pa9AdqdrDU/Q327BeAUOzskbDzQZ
# DATA sHO1J56+pkDe74M0+NJugAF8DGRe0Egy4OU32y9QehEuXDmxVRSKpp3RkKoTzcb4E6Xrtg4V2QuREO4wALJVpd3DN52YL2m1pYKM
# DATA 1bhGAUtaKtTpZmrgla0msqk+JaAFDVgGT+cuRnxqZeEZn+pQCftpYEuWOmiO7xddbEDQvwNGctoaIh7JqsEjwTsSkkTdgDPRpjPT
# DATA Iq3usivhFtsDDHqDzOTjJPHh7vi23dl4FFx3ubhybXCac5JJIiWrE8NpsN2i4g69sQmzAUhd0WBqEzbdnzIq2u5zJJRpDaFW4yY1
# DATA TCox7myD/1ZiMXfGON9gdRwGUz1UO7MBu1BKMGWNk6PDaVrdjmKTcrvR/KCznCMqMfDyymApdNvE0upwipfazloLi4mSUFet/Ucp
# DATA aZKOdrCyzmJJ94YRQ6jz2tgJsVDeG3cf7ALIinglxMOZhsVSmd2z99kplrMSWijZS9AH+urASP9atUyJ38hp3XGKdqSaV+GCXAh6
# DATA cuGBnky+WtCTORwJ6V7JNr3iOivzoqpYV2kwCa6tXfc63LB+1zhUN5fLxdYTk3mpgFrQ/B2Cl2Rz1KcMxiX8VywpUJg9USMAhNrd
# DATA rRUO456Om1OJPsdaqOUc7tBwF5K7RWIBn7goDenUQRMFlmprHOKIi0Zy4dSnGofRabSvOdhNh9ly8IGq8d2drQd7zY0Hd/U9NvE+
# DATA wXZC+veJ36IeVxm0ydjIgKVriihBtD9cnQwueEGHecbjfQWKCmjzijPDoPyS006q5o3kLpIMjYmWs+9X62jYz/MEMxSYYG8Twjbq
# DATA I+D5EfpWYqZILuy7AMMPj/QnHGtLGATqPgXBHGbA+JIvZ5vw0Vtnh52TcX+cc1wuR9Hm7MkMX2kNpRwMCJDHB/i+uNfg9UgB73Hh
# DATA mCH5SyIWvyTKufScFf2H7cPVtE9ODP7BynHG+lAlm4ltVGTeYlYWE3hsN7xey2Z0p2ys4zgqget6bXrBNNTvCVOfeExooP62u0xN
# DATA l0G+MpUA6QLQrCfF2F1R0m02ptNH9izVcOp5QClzQSobZJMmvP8mpAFw/O7Vbhl3R1YJmGcErKiaaY3UFr2OzGhci0wICLigczA2
# DATA m5gx0eE6/wzBtE1R/ac9NPhhkbUhv1Qnl5rlA8pbeXo0rHX6S93+CPyol2y4cAAH4zi5iEGgpQx1zZjZYaYYkA7LUW6jlqhR1RXj
# DATA +VN3+4KaNPO5YRHCRjohz+HjyezVB4XPf36i25i98PXMdopnrvtRdgYOajEZ1osgLwXgAxqPQMuN5oYJnKdAcqgjNA7rJzCRUAMP
# DATA Lyxg380QVKftNh6K3i6Dxa/VqlCa4/HA3hj0FkYzN7qK/rRbWHFd92hK88vGC5ygQiDYWLHdkLcTuZGGwN1Ql/6eVLdK+4viowMy
# DATA hDUodvyoNYAsYs3+eDQY65sjwp1qrNxcNkST+0ndAkWo78enGaMw+2cpff7PlJj3+eeA0a1PWfX795iXdwYmEWMh/QYxjAD36O8w
# DATA t+/HAP19y0k9qbNyf6L+fAKFwNPfQfLJFx+5joTcHYIjtyOMBm4YrBLhi6B4KN1KAj/2EA7DczSJObSDkSrUPmB59r1W7+jU5XZ5
# DATA hDkn+T97qcfnGUUHJOrT55973tb7vq1/4DRJx2y60iLJ8Bhwg2PhOr+XD+QomFe1/K/DsuBBqeyYGQLVgNv9/+mkIP2tTk76cgPB
# DATA q8PA8VQS3R1G4qF9WmXxM6qz8Xa0l3VAFGIXDSn/rA5JbVXImIzDgSA1ejgInm+Ibnj7afWYv4Rn5YMDjXPAmleKsWiSJYNhfVDR
# DATA wbfIONUkDyqTkZjzNMZoi6qsm2WDBqEKw0+LwCM3iVWaxhDiIQrIXi0Uguza1vNGonOCQyxk4fe19cHGWoThJbDDgs2KlJ/fNTNm
# DATA 3zS36s5pFcnxXhz4gWkfGiFxKS8UBQi4lJ4WDMM3pYu0JJknAiCofhXFmgFCrZt7AG+EdAhzUdLtY3CrQtUqW7dhhuHI8BWt3hG0
# DATA 4PkVOW6lXtgA8mmFe/Yf1U79BW/OzxX58ol/JBlDovbpR+qtH+G/HynS/iOg9IrG6x2vwy8ZzxupqF3m5RrhtIP1zUXyngWP7Xj0
# DATA gbWh1lYrHn6wR07ZV/dFwJ/454Hz6j5n/T7Q7KDzFN2U0sNxp9tOpauS/fqSUEau9sEHM5oNL2UrJg2brtMruOsoHKHkTr9mWFKt
# DATA fqtCpiRVfoSDnSw4ric4kYJGlUOvE4TmA72aNvlg1jRt9amNR0c45cdwp5R+/TtfP/t6e+/r73/9/td3/5L8cqIeK/v1mywkX8Kt
# DATA BKPVE+3NAs4kFEGHe43Gkc3BNHrEYIgAvOiYVBIHFryuNyFEVMpAtHpiltpkIbRmY+MqpgXlhWlOMNRuWvraEWa+L7Wq1f2Wrpje
# DATA aYnTGSlzV4yWW4dI/CU339NW3uS89qpAK75rTEKB826Eiia6WXtEdpATjWwR0l61+r1xB1N/mvHWxNIPyJDlWsJnGxAh7A7aHyPD
# DATA pxWnJEGcpTTo9tdBRyyEXGRnctas9p4QAJL1hxUA+Lb9xgW3XRFw7QLTUjO5wS5lU6XE5mOJp1n3HC9lYyRcZojzJ5vjIf0V+HQV
# DATA LBjXBcQWW6T5jWBbxtS3gtXXJdYXwtRYNQc5NdIpUrQY4FQeOCG91YvlQHuSkxKXhrY+0+dN9NfbuKaQCMBBsJZnsMqBnFvACEck
# DATA fMvn2gyCBzMZI72B9dAE4wA96Iya3GhNIsW6oSEKWeNybGYltpg3bqj1VG89ifKBFZfrxWaUAynKFPRGsjvqDwYIoXSiYSpzulVL
# DATA 1hNNHTDLTgeyqXPqSVQ7K2E3QURL7WuhRvAZ2ofu3q4Fc0uNVqM5HhjGsp1pUqkuNJMSwShdVCuj2qboQkm1UAmzT5+jOR4kpJDK
# DATA ShWN+Dx0SmuiRxpEBJRuLJfj0ZwRsm+6dkXC71TxSmm9f6bQiF2EsRmnWauLoZ3Tj4H38TV5B14Z53Ffx/mOFLIycANAH0l0K6U7
# DATA 576ysaj8It0uenOSPhjApIrpckCRLQeLZSBVne3xx9LJvyDiNogfIGcgXvevCXkbtAifA+w2qZe+YCHmN4iuPVeyuRk6iTRuyDhU
# DATA W/dxbJr03DfU3uzpUcdonanzp2eedMhtJRhRHJCiQ+2iSfMG6ecz5TULXP7i70BNp1HMGQH9xY+S578EoQ5vMVB5dARQw1BanQeK
# DATA OaIb+gjUgqAcA3XgD9XFH5S4qer89fPPMHcgdOCnl5qZAtF/DvIdP4Ob3dY5wPuT9uPVKy2YciwuaubdHtHvsld7rEsTl2MKWQep
# DATA VsLfjtG+wIlYF8E4lebYpUN2/iPVQna6Hv0eP/9HPLHIFZg0cSC7lQwezzDHtCLak7G2PjwZAznbxiclbQFRfW80m+rYaDbL4kuw
# DATA PzRb/Ekp7Q8yVnohBjjoGxqwTPKjPqOE54pdIVc6VghqPoLUilm3TWpEiukg9oltNnBFJgEsiOlISkAY8KujjXBIYlMT/VAFGQAu
# DATA dcIINEsh2wQ/KTvDeNiVKrVo96oomWMrpwxCtYo+9RAadD7IGiabEHDF6ISB3+Af+Cq3Yhtc1cwYIiU1Y1fEM9M3OCwVaTt1KAC+
# DATA RB4h6jT3uDt8KExjrlEVV7SWU+Jt5DkVfDhNvU+H8FOaLoeXwvs4ZiZ6irXxy+CcJx5/E/32uHjftBwcnIpUfvHih0hnf2ftMJ+j
# DATA 2UeR/UvR2ag2mDpkqY15sVAVDJwRtX7fdutg2tRyZjZJ05zTRuvV5ctUNAl0+JslOfztaNjxjpEl8Mro2o0W3a6eptolYPtTk9ZE
# DATA w0KziSug2QSi0mymEb80IjeFLlQGtv9b2fls0H7Q02ceNOQQfBDS5z/Do/xTOr2vYsCDzLm3HMaAk5mwTreCZj2dwARz7sKJ/sWL
# DATA n0IlUJhab2qVwSH/Wygd6q8laiV+zK2BrClY9Sf47YdoKkMeTvEEyNJVEvXZh5SFBZTRfysSCmPLPoO1i8YirBPgKUHabIDvdj5q
# DATA q7ERS/Gc8qWUVv7PiO64ZPwHyqKvHP55RvzHWytrq2/5+M+r19/8U/zHHzf+Y8fCPCNQP+Q2hwh80pAH8R/5LXX+KHp42BlBKh7t
# DATA HcAMXT5fDEiIGq2zpzXZxh9Hir56RAhmX/t3Hx9yKVMstjEe12WxuK36yiR2qgjnHckYMRPcgRD1zuiczJ51B+TVjWotpY+W09p3
# DATA ++AyC/GSIJ081l6s5MMqdYWpiBbR1spy2WKZOJGx+/XVtQODJHvUHwJmogX+wLBT68NGiZxEALRBVAxsNHmqeUr6aCrkoMwBwZHM
# DATA Oxvvbe7u7XwndRFdJJYLlXvS7R+W0kWN5uj4Imo/ikjFl6lc2Nkd7ssNF9X1QXo5VNVEJnieRJnvQf13tnbuhilYoaSp4JNmzkLX
# DATA K3KQjUydAMNcMP2AW9YBRbvVmvuRAY3yp8IHPETZlGtmmzRcuqLZMJtBT6M5hMn572nrSVaNWhEpQB9eBGht3mLRBj5UBAkygxyg
# DATA dRg2fKtHCD0gn0zm6aPlwl+qo9P5e0aD73W+h6AxAt0RVzC4/kJhgn3HV2WmEnfhkvHBwa2jT+LAdW7G8S0ArPsOLupd15mIytCR
# DATA eixjuqhDeGi22lX0KrVOlf3j5HGv/7THyvwzVPgzvdaO50qKy561jvSK1WmqSITwIICnbQSz6JueSxaSI3k/Rts4sGgi6i7eJS48
# DATA oHg7sjps9TNBa4ua40hImjaIfNyieGdHBdVKQ3xFbLi0HCbrxo+j/thCk99p58Ik4VgKCswS2uO57Lok99RKzgls/4YOYIxkrm5V
# DATA jyFM8GJltXJjbZLG3fmgpHlJ+J2tB3vrmw82dgClb+PB3pZ7kJiFfBnLyCI0gJx21fCQ8s1K7Wo8+k8JzclOwFIBxcPwr05/aeqL
# DATA MaW38Q6fUcVlnMgnYRwc8htIrByqJTysC0wX9nS8hHt8xBEesrLQgAq9iPYcFgvVKpnEVMzl1R8FBBFF1iCblVoMYSTCvinuQEZt
# DATA edaAiJZDKzfKc0C7ynHnFoXnETlkmRDRNIYfFe0ju/4V+AkvxAAs0C+DTfvwhxn7fBKFErObNqLHj5tzZJIELxoxglwbZk2Yjr/B
# DATA ybDUYWPyTkR7qfEH98mKsIj1cFcL4pOirsk0UgX9CJIHFlolg6PNBHFjZg2ALsindb2QvUYe14Mq8uru5zWd/TDtSc1uCDqGmRiY
# DATA 826NSuVp6GjzJkkoxbIkyOgyGhnyWIfbwfsrkAW9PB0wbfoAbX2gjpB4dtSYz+wc2UjLc8I6E7Hbd/nAA8dBjwPzFEOAblQTn8ug
# DATA IhZmpkedS+ca42EY8xIV/8w2Vhg4A4l30/KUTlhWCD49CJIpFzAIq8gdwOtTBVhHkrMJgFh+lDI2Hk1Y3oKMu9EmCIw99PpSDwKE
# DATA PNZ5epkzM0QDxjRJvxs7G3fTYoiFeRAW/KCdeUZtd2Pn25t3dGLqN5Ak54migcivVymITbPsnPwT3N7UECSHkIQcT93BeJTXFoID
# DATA YT/iR7UYOyUOAuT72NEwO4nOFXQPPnEs2O68E+CGhvdmLJkmZYPkLRGCQhTF7NhAi5rtyZwgHBYcfJ/3E7aUDxt9TTBZcgMwrNlC
# DATA SKmLwojEIDe89Ba+oR/ie+niQEqv3FbMQDNtRa7fv7353sOth7s0JXvrO+9t7KWXgzMXfbeY5sva7z2gXR4sMGL8UhE6m2noMGhU
# DATA GJb95VvI7U6Mcm8M7EF/qBdGb3x2aPBwUNRGOpJwDCeHi0Ltt0wUkQYvGmRDCJvIMV4bgyNxU6JPHfgoGHkblKOYGMhYg7EFXDeP
# DATA 5Wx5Lybmfcki3lXEO0eEeRWyndhWgUAkKmMiP5d7GoyQjB+VGdJGRwPxFszaIUD7904swsi2mr60TLHzmG8SoFLpJWgU/8wZ5cSR
# DATA KDABrnkB1Na20VPi6KFGiVbAQIgHGpugc3ycoaPh5rYt/QzcPwFXIGlhO2vJAzwhlDQD61gtb2tZgXQGGURWR4kEpNsq3t9W0gu2
# DATA 98wAXqHTLa5glqQ1oPBwl1VjKsJnpMd0iIcZ5TjXb4asg31NtlB8WkjDuIALY55hZB1jm/E2ny01cLxCfO7QDU7QFEf4mRl/qnd/
# DATA ebawOJkrYTUy6ibVy/3N3fvre3ekbPNGsqfopJkQ2GCkndR0VU8fnFdPMiS9w/y0MwBwjR5FNyZkdFKjTqHyAUscOy3kqEbPDPtC
# DATA 7OSYM7Q31CdGklGBV0cLvIuboz6uFrEUZuXeDDbFFUARFgogB4wyiLU/NV8dZPJUxbNnFeXeapCCWdzpDz0hy7TltUsiL/hFeXy2
# DATA BS8qxkMoMImUy9NoXZQRZYKpV3cZEqFcwSxAKy+CDjYLw4tvulF1IQizBMCjFUy3pa8q3SrRH0rkQK2SaV1cD6l5DKEQoYd0GiBu
# DATA yUwpjSovwe7ZXmg2T2vwhc1RnlGaEwnncprTvy/H+cFesN5MLVO27XEyD2/mYzXOyY255qUrxBxQTBkNY5dEKWmN8vFctGk8PFxD
# DATA oScQ0oOMCpqbhfvBFgqd3skgKGx2QugqaAN9EqvYsmFaq1NBo2bECDnryNfmLaElD7O/mcAQZ7G6yCJcTjTUTHC4wUdjk29wVpyH
# DATA l82Rb4NqSydpcXvPZ060RbNPnpmKsLnUX7aXFdOgdNxrPWl1uq1DCvlKF+IgLK9GnKwUKTRTahfivFMDU3YVV7cO+/2uNKwbkWRK
# DATA eeRLXad+7teVgHfgGd6xVNtM+2hasVZxWbjsJxFMFJFs+ZwD1AwezKqOsILQEU4PgkfEWV/Ru36vc4QJhPh9itA9BfyK4KVvmiJi
# DATA MbPx7XLpreI6KLjSoeeSsJOha799Hm6YsuU2hvZtWEhuHE3w/ZSdadPHm9ipKIpXQZeccsJ2uPt+SjPcOKJp5NhCf+jAnKnq1fW7
# DATA oDHQGmw8VR0FtnFutzpr6+9umTuMusBAhP6AGDtxS1Ozbl+J0/Prq7e2N3bW9za3Hrhq6/n07Db2xGmxbm1Bi8h9ehpnAjEoLnPi
# DATA cSQHboUYEkD16TgVrBQLgLR78GtlednEvxz1u/1hpNiyMKyKJTetraYVHDpjYm0ibdQTpnU+5ZDVCkfztQbPuGS0NFXSq8p4i8hT
# DATA Wqj6RkpiIU0faPD07BosE7RojcCHBsAUOiP1HqsDITAWALuyAWh8MMmCVvbN4g/+3UK+uEgvFrIkBuIijSoRkUu/PNPOwmYO0Bbs
# DATA bj54T6O1oObe6PvkUmR11xY6YILlqt3qgpGI2U9Ai0cACZwn9sfJa4nW6o5OWyOhV4Cp5xLRvRVWAakkTkAVhnqG0dN+VS8ICz6v
# DATA bS0tjduJS6LGMBbt9jkiMxXqCkBWuqNfI1ZFtapJAdcNwLxQz1LNr9IMOF0iHzw3eXSMBaDjJjPJuHKk5xfesFZ0ja4nAXxrOhPx
# DATA g3SeWVUAbRuPbZIitc4WZ9CEjBCqRMPk4lGPdjMmEuExCeTJ+vXlleVHvYlMkHTWV0KpSMKb73O3KC9a+kQt/zNn7HBDguKesVSF
# DATA PfSJTpOHbupUAMSR8YkIOta0ECuV3+eQOPyCIAp4wNxScblzuUvZ6GgJ31uyC4RUdLAcqItliWZpVo39DaZ76pY7hRbtCL2gFe1q
# DATA 6IwlULmeF0tuTYl6yl/JIquLnLK40zVzzi/YODywY7Qs+rUmDLo+yldLyyyDEvImZWaalD1AX/7SEWZ0vr2K1X7qDkQSDRVQsPfX
# DATA d5t3N7Y3HtzdeLCn6ZnW5syBEFWUTIvSaAl3x2oc3CieUOsS0ERGVr0E6pCPLnRg3Wt1AkMe8LrQ/m7wMQpwxuNWl2N16TgHpApF
# DATA vftK5lQC3C2GP9GnZKJGSM25KIvjQNqtTAkOCXMQyRmAKpNyJQcxQBHyVi8Rg4jnsFUaGzoBrT5ACfDYhG7vC8hUOQ8w6lDMQWEx
# DATA mqGBUtJeP708oJINMpz+2fzvz0ZfKvzSxV9yA8Dp3C30JZ5PDXgFp2RCPm51m9QA35VYNKtMFhxzbTy2PMhXU6KJECjwTbZ+ydOK
# DATA s/LqBayKunQq5n1mvYnhjUk5tn9oY1FW07aDYvXHB9wpXCJzA/CIZHEAe+5FZZVELGU8xNhD6SnYHVOWskbxwfwGqUk2lDU5+NbH
# DATA ETDzYICzKfS33RplwSKMNicIpfHoroVf4FIDY1ww6VEtdjj8LB8vBkfhJcsZnhnxAX3dwwL55J5jxUtk6MjqL89leNzZuL+lZHfU
# DATA KtzZevDu5s79DS9qyN3cbql6v7tntPtF2U/CGeWD6hGvXQTWD0J8DpytbPhXbdtkRP6psTN+i8zHyH5rQ7i+yzD/J1lBG8m4PmdV
# DATA onGWNJSL4UjE+5rklKfiqHrDF6CqFGyNqJOvSXDhMC0AYeHJU6nii4ctc6Nc6BDMJUaWUth2SLQBvAQubLnCxWMwCIVM7kF01EHv
# DATA MW0xx3IV6qOqknhr2bPh2TOyIqiSjLihKC8/mymjtEwcA3YE5cWk527Hqfks9JfoXp6edLN4KGbsb5+/uEQtzjh65fhwRQWsSaQK
# DATA 8VY0jaUVZtywC4Z8iuYu90Eq50pgyvCSaHXwbNTFPlflgiTPMxRblwfqmepoLkF8pgP4uCnUbf5ODdxvV72xiIAusT2n06k++gWl
# DATA rAco34Yw1hOTv0zGdBZFEVmOeE5u3PWa8vlys0RfMnRZsVZPOpS1JsKql916WNEk0e146E0xQBH5dyw00MTqOu9IpYXl16VrKIFD
# DATA Szi5ormsMKW2CuXtVp6z46heEIxrgALPkbqGkVbXqM9B6IMjbRzI1TTYxD9GnTzFP1lPT7FHzlx+GeXLTqzvmq3BtdnmKid6zl2h
# DATA 0WeTWAJ5Ewuqy0XHsd4Tu06cI4afOOMA9ygqBoJT8s73s+Tt5Mabb16/cRlv9I0H3xa8kHVKBU+ODiiiu6Vh+lcRvMFGSYQGVA+u
# DATA PapNvy5/jfBVp+nrAOqsdj8I9TQOmw3HYVNOk+eg6R5eBJBO61rDf995uLvX3H14e/fOzuY2GMXU1n64u8F9A3UIFU3p6stengFp
# DATA KmMopDCdAJ3MFm3CSRjwv7lBZQ4lIA14HCQ+agGZZg2Pozj7IxyGwlAj4vDz9nkRAL0LhmXhnfWq8+uPvDoVSppm3b7M/S4XAylf
# DATA ykUFyQT3kBzp6HbF74pppkBi5vV0FezqotLLcpqbvGHAvWHOXkWdA/vDE0CM61mfeQInqwk8PnnqO6lkH7Wvld6pP6qpv+WL1cp1
# DATA 9FFz20en7hzf6fcdwj0aDxQxP2sNSjgeXtnaIbUGIC6Kentvx96aS3lwd+uDB+/trN/daN6+t3XnW0Zx4IKpE7fLI482lfmgcOfR
# DATA 8f870uu72QRC+42v9/dp0+TL0HRfXXN9aR35NE33l4Sb/gYsSUp6kGdqFtWP7vktZARFiIH2kM8ziNmkp/1uF+pLyMhYW/jfXg8c
# DATA 03K/OvvCq7cYXNFi8WrsC476/5Xrw0MObXGxdJH66nEN+1PEYLhZ/8AqO0uVPj9o/tWV7ldQKE5VkX/pcMJRb6hZ+PfSG+pyiuvL
# DATA K8RfRk87t7YyBPeeoncLfalDzaGjKHefTdO8c+FGoy6S1s7zeZGV4FIDXmBbEABYL6E1v5r+WAOWcy1eZpWp8N+vQjF8VWjwPymV
# DATA pyiVv2rc9EJCJ2HTjziHqKta8AQpG/SjV8UTZrNIwyfzuMU0Fex3rc3Cvnqi5FdXtoFHwt80pjQMJT6MAjfKEfKFa5A1uv/svJFq
# DATA RIN0NmTBnDgFHJAeC0ZfeFUy+VxDH8t/6uJHzBFuOFd61ALpb3Nn4w6ErqPxeOP+9t53bABVR8cFX0KJ6ahjDeumY8lFZxRfj7A5
# DATA VlPN9bxEm1FJCt56xjneLB3jfDefD/zO1l+IQmlJirhWHaQYjxh029Kw7qy6p355haL5/fVNUDb+l4ebDgrLZUDxSDHX6Y5IGMI8
# DATA hA1VQI0R4LR0ybOI6kw9ozrAD1XpYopIAxARtcjBFJvTzV91K6bOnA67VjP352p1NDf+YnN3bzcNtqKTY6xYtcWpxqReq3PsdD9c
# DATA 5dLVb9060w8zpolJa3h02nmSsfjKZXHS395RdkvnwRJhvW8k4x5GTGe2xg7gXLZ67ICdgW6WoC4Ph7DtrXcf11ekdzENu6RvpSh6
# DATA LkVMQBamR0d7d4DsyZjxSDFXhdTxQ9TxnNCDtqTl9LHjBWLfn971CuHwNPuPxUjYj49O1Ycl/M4orbW+RNCVguyrqq2Dbusoi6bb
# DATA a5yORoP6kkVnrF9fphiX2MswzXob1Ia009IlrbhzebDQNFWR7XaQKC7cwD0RllQHlwq15vMqJ2ZD1xPFpqKOBFJ1Sjuwqap84KWK
# DATA HiAgiHr/OF1Zfau2rP63Ur+AuxP0jU/9DzgFax3adsncq35J/ZMTimi8SNvDDmZFIZtHVSt6+gOtJLxIz1rPqmBzg5dWls9I0fis
# DATA yv1Nr6cTvwIKNjs6zY4eYwkjNXbQ1fTO/bvIXapVhzQV/z3OQNP8Os+7HQwYhSW03SheeYnKfL1cU9SnVxo23tZxppiZYVjrP35n
# DATA ub5SLteOUHFdKntvqEccMq0KVBwNNP1NJPIc0WhvKNoGVErdWFmlKLThqDnIhp0+uNCkq8u56nLR4QojbpPp7s+O6AfRjn66Bq8L
# DATA Hd0aeA/QtITzTGGxtml8HPht49vaS5pjr00GH0dtQuYs54sL84VqxcR8BU0CvE+YLOtoxF3gAmzTfN6iSCPrbCQbUKHZ7KsFnJSD
# DATA Dgp7nQ45cYgA3ayvKu5k0Oll6Rz0wORhhoF5b+vuxu2H78HLZ2rkOiCyjY4GjeUUB1CTgvTmcv0m0rq1tet19f/i59K4PcAFrKNg
# DATA YqTGjhD6gdRj0Sj1Yd+wk1UIfasvwb/2Hg1KfYn1vI7HKg2XbgINki1JrwhZDt6bzCLHxEdVNR+l5ARfff/luNx4hMv1KawjgEIp
# DATA XCReYLbv+RvOS6R7ZSdMnX5MXgKao9ALSCrTpupBC/X6cyhP27OVCVouc9WaUR3U3DaviR/NQGiCLozUHylbG3OnMkVbxTJlXsY0
# DATA esJcfhVgWE3+NXMmGwcpFEHUYuB4cJQQqxyFhpRpnGdVICr2ikoinscPYtZHXCwI+2BqfjbOB4fp2bZRtTXM1Mpxg6il12wpReYc
# DATA 0b8Ks304o+IOge2k7p7JVWfhHfAAKEhTV54rM511H7xSrjmcGz8yHP1X2uOzQV7SsCyUJgyQVIARzdWiaLbyo06HkV6nJ4vzJ35K
# DATA fT6kpqmXM5UJZQilKGPJ9QqtEmtvSoMEiqPfFrh59YrtMpdh5XG/wDlHQWZ+Qx5/ejv0FvV7rxWLl6vVJIurkIbMb4rwMDN6BjGQ
# DATA II6mKExEctkxBwWvpLZyij4VOsvp3dWUrSCPnpxYVTPmQw4aEk2bN71aS0XrHnMCeuXpVYsxdXSiMJCo3/QHeWZTHLIdQBsbx7eC
# DATA ZpWL98nF4+yc/Tgw0sCJh4iSz/LkCnvHEtwQziJQGoe9MMOp9cf7ywfTKxREvYjxF8tdezO+itmyZ6jfVYs1UTRPMUc5jXsyfclZ
# DATA JJTZOR9hjiH/2BjhrkqUiqy2u/ne3sbO/Upir99/uC3zFtF9+lOiAipJt3V22G4li826TGJY/uqTSyppIccMNz4IZkq6nPU7dzZ2
# DATA d5vvrm/e27gLvN7zn8m80jYX9e+e//7F33Mqbsjx/Px38ORjzOT4ezdD9fPfUoJvTB75syAb5ft7e9u7VfXpryDd5YsPK4l6HVNR
# DATA vviRKpKTV7/4SSXhzz5UFf69V9tnVBfkvvxYJAWHi1mJM+MZLbH5nz3/jU1P+eLHNV9MQc/d5rtqrJr3wbn3NiiON7+9vreBQ/f/
# DATA qFp/+/z3yfr2ZtVpE3RQtfvXmLec02B+DiOAaTN/rVoDSTlR4sDOYX7Xj3TKTOrk8o3lZdX0/8vkP+cRx+uPMQ/o50GDtWHCNhwb
# DATA +n/jJ79WIwITgqnXf6zmlhPMUvs+gVbprOt/XdQzStlO+WghLy236hfY30/Vz5Ubybc6twsbZjSKsXaZJeJN/i/Uj99AO38ESc4r
# DATA +BSr/z0szM/09cc8jLgA6wnoufL6EjsYZc9aZ4Muuv4EjcMVyk0zVhRo3z9RDapVaqn+EhaP2zKs7FM1mj/Cij9UL2NZat7409/z
# DATA dP3+xU8wcepv/XWt1ui/YU9+8vw3qpjf4ki0xqO+bOXEs2jsnkPWuA2gMnrDoysFyMNIEEBifP6vqmTM6friv82Xpj1MMTtlW6uf
# DATA /5A8/7Wakx/i2v49zgRllP1rtZ5+iU+o7r+/halon/8Op9dkNv5E/fkEmgBP1TO1KD8Cj9SF/zD5P0fdLyHh66Xyv66urq3ccPO/
# DATA Lr+1snrjT/lfv4r/Xn/99TvZcETxTVnCDgCYVBRNp8KwRPJ99jTZ0Vpu7URBfsbTU7xCQSRcv3zS1qlpWrOzAbCHC1Qg85q6QBKF
# DATA Km56VLqZVxJkSFmLBO73ed4tLQJfV0HksAYZWyFdOrDdTPgaxZnTtzcUHwfUTNGxz178NVMwIH9Mf5jHgQMYifEX8KI6bYgNcvii
# DATA zyiX9g/hAELy9js8Lj9OfbhXwa6pzpf2U+4J+PhAXzAP12A8akCXIM/rYAS96Y9HcJO0+QYq8k1hUkZwTlK8QWLWKUZub4Qi8JQ1
# DATA TufLjkJ2BTYHrc6wdNrPRxwjax9VCJFfTl3eSI2vDXk26C9Zoam+Br+PzhNysUdZQxRZZmlbFSxgaJEddz514x/AQeQIQYjUaTcg
# DATA NBC8Th/1Hg0fLacz7bzP/9EwE7BI+NjTPJs6phNkkIAhAxaVWTJ1nqvV8t/V/P8NLAZg2j7BT9QqCXOvDrzsj2Fc3cry6lqyiH9m
# DATA Nvjn4drj45ZXsGk8HOu68apvVc3KIXf0mWTX1Dn+d8CwJfc7t03+HMigiV4GSd73yRFMffa9MZiewfES3NPGOQPBaWhA0D/CGqqZ
# DATA BdCkha7mGH+Bh5S6S5Ll4TnkqiubiXbukjc404H02ZvL30Btd68PNkT4hXbPrIc6zps31tB4jYTCVKt7taVK2d29p92186SNaSAQ
# DATA KKyTYwQO2OFHDEZ7S20TkPLVRPa+nw37GioYBsG8TzvWZIE4TNv9LKegQbltUu1kNLMnsHfUld18bl+mh2zH/gspZXQZARf2KyCL
# DATA sIo8fveXsBdgbZGU9PF0t6hXUb6hAzAOuMsjZ0XJoUJ2zDAmwHmmsTIdCvJK5+rl5+kSc+XKlSBbANdMshuIj5/AKSVGVFEDdedj
# DATA FCs+Dvj9OSjlV9IKztJAvETepSUA7AM4Qzr8A1/TEfl9HePxRgLzpCZ+gBbe5LA/Ok12dtdxw27cubu7fksdUIw7fwbuN/j0rN8e
# DATA dzsYiC7I1WB82O0cAUxgsAjUI0XGnPUQozdMzCIlDfTn6pFeT4MW4IeTPSbP67pMTS+tM59o3GsNr5Kpu/JngXxvzw04DtQ0fKF4
# DATA n4+Q2QEpVv0iiTbK9Lz4kfZxgkyj0YGyuwWtW20K+/PGqtbOKMO8nx9AlVXD12CSm6N+M1cv9tp5CSvUoYsNyrixcgBRjnph1Hr9
# DATA pyW9Nmrj0VG5BleqFWeD0gzahfze7xLUZf2WRoHF5hjjB/LvfwcJGA9URbpe/C2K+R+++KmbWiByBhoH7cH5bIZLGC6KeC97rF6N
# DATA jePpzMASwSpc32F6KYUycgMyIF6eGxbh+T/T0CHL9EtsVO7xXkhRDO8lmCyjPlED/KFaw79HTcNv06DpEX+7mIed+CDwsYMxg3Vd
# DATA SiE+9+hUnTi1QXZG6v/OE8iCBZfMoHTbNsmDNMFiKUL5TcmddK1L8FieSYNLJf97/v+iAulTPFw/dRg9YABdflayhP6Yqs//gMKN
# DATA GVXkEwU/qzqoYUcHDn9GrQ7D7iJabxd0BxhINUDfV3seB4kog9fn1qh/1jniuvyBM+U4mnRWns9freqaH9I1bZYEDBCWlRdEpAx0
# DATA kAinhnCXXnGYVtDtgddPP8LDfRn9AvT7OsOAziZGUD2QaYAFdLVPQIc4gD3eEJmDEdvvuPOskdZG3byaRmYTMQj7ee24DZS/JCtJ
# DATA nx6maJZQJD1rnfmpKOAe252Cjok3jrvj/NQLsYH68vPeUUm/o/rQ65dEpGQ/N/6uNOkYJUr7EqKAuqILSN2QYyycK6bRBosmL51l
# DATA o9N+u8KBxB6sjcz7SS84kRs6vaeQCG0KYikU3rh+cy3y2CYWfuutaTT27oNd2ea6ogXqKP+1MSAI0Q+o6eaDTUM4EtS7a/sDkoUb
# DATA Sqby4EGkKqlGeArsy2PRPwwwifiUSAec9L2TUrrf7uUHj3rpNeymMK7r+cq6mOYRkKWNX5j6xvjJZMOzzojCWksX8KR51O2P28fd
# DATA FlhkBx0yWqYYcUvzRkZk8xKj6NO3J0d9+oy/MlNX8KnGVaZ2Eoqz34jsjDMHRBoHbKBAd5a9EcUafkjUBJyfeVtksHyC3gRqRIHE
# DATA 8cWQLwwoNhVSoyy4MwIlnv8jLA5cM8Dy0ypSx8WLvyEGHg4fVuH/go0Kn7NAp9Zg1ajPPibrILySeiAuEkNH95WhReZmKf4Fl/Sn
# DATA z3+jKgMr0IfWqPUjPPDEZnDqZ3J3Ffd8h+xSaRD+Vvtuv9MrHacXjydgfX0CHrDkSVBxhl9DZtcQqwgT2jGtAW9OwbXhCqokmuzM
# DATA wQjGlHDuKgbLUuriQEEtIrjKASWRqZqvPaoeXPsze6cmEZkOLlYrgFiCpc1mX4pUtrRpLE0/VZQBHQhTdj6m1qbX8O+1FP2McdXr
# DATA jsjcazjb3dxCbrlnri08eF3/XHrSGi51O4c2v96Sur3k8IVFLwleUYPvGypKVV/TM3UNnavTa+qza2noY+2GaAgwf1/bIfqmSs5J
# DATA HT2/9sRz8UmuNZCkXAMqRqsbiy3P29zqzGwEwgdFyhrSAV37ndIeAWluqPHz1UbA0t1c7d4StuDkraOzrLqvk5AbGDHA2uACZ9Ma
# DATA b9EqqoNuBH8AOfEjJHZ/cIgdt4nYAmpsGLtpNdr4xlSN9iU2k6GBaNH9FYqonyXrd+7bdOk5GpLVYTbIjpSACNmBUWfyLDvaRaT4
# DATA 74374J6GGdXb6Kp2NCLdTH6adbv6OelPFCPYGtAphh2x8UePHsEaeqT+S0VU0ut083V57+tw7+tf1+hCdn1QxgduMP9Ny0t6LVxL
# DATA dYCOm3Us3X/Y64wUr3FXuBrvZK4hbe/erpSRH/XWjxUv0+BoimofWMSMHaQSDkXk2h71PmjBaRF9F2mT0xj2eVft2QNnXsUk5ad9
# DATA 9d7D+638cWNZcXePemb0G68rQkdjei19/REoifigurG2doUBws0z1/DogRGDovaVGrRWF/q0vwclqa+2endaig9vt4aNxar63//f
# DATA 3tU3t3Gc9/7NT3GW6zmcBIAvouQYNipTJCQjpkgWBO0oIIIBgSOJGAQ4OFAUI7LTtJOZZtJpp/0A6fQbNJlmmiZTfwb7G3Wfl329
# DATA vQNIUZo0JcYWgbu93b3dZ5999nn5PcHSw+Lyo8rSUgX4lPXqDUFYYt/8WdzfiIfdi924V334GErtgFIecipPq1Oxx2L9dbJstml0
# DATA 4/7Tiyp2PlED64yFx/f8Rm7nc3mcyzht8iY/RZWeKWeoIGJ0iAbsAFLvTY9VHNRESrKGq2HL8K02tdLiJ+sNLVdE2tXRmZzSp1h+
# DATA 2wljbamwDPiKL20CSJ+m3bIfKGtc+qaUaTkwqSpR0NIlLc5/NsFBcZ8CpdWp39fb8SZUA254obrarm5ZWpe7ZUvf1S2jxqtrR0lC
# DATA n0wXxpS36emF5fMqVXWzmzE9ja/XpkFCRtPGCbRblsKgqJlPod2yKUL7K3ZCv0jQNN+ERU2z/hu/BpF3xcp2B+OmNm3xlXZCn58n
# DATA o7EZKJTkoVomXLL0WTGDZHjd2ZLoh8GXcXyKlkqJDRLIrRhP3JAoc9QbnmGCevDMOBhPwyQYQqQvH0iScjr1aCucDmWUFi/LijGY
# DATA 1mqmaCp+KdMYXtZCQcRL3ioL69IsY+egoo2Ah8lCcfMrm0jQNTIbToeJJ0kqyy/gp0RgSMaboOxi3YU++/BTvDILmRe+/f4XdHz8
# DATA /l/IMQMPmGichwOm2JkdXH3yIhZNtqzOtKNPzVvQk/YcXsA3cs6FrTvlp2spRm7kuwvW958SGABmRWMVGYlkkOp9AMcVgx/oPD4y
# DATA uj8OhuOjsuNxHX73a8OxRYxoRRygDF9BhLvSCb1iN9ss63ZD0yWGnQDRxaa+VS9qhwrxH5vbISQOXqRq5CfJdmRc/n/k9qfd3w7P
# DATA O0dn3Un/HXoB5vv/La88erxi+/8tLz1cXrrz/3tP/n/NGGzb3clgCMHUCRhaIBkXY3zsPftaSLGYoo63oyLp3wcjyuQGlogJZW28
# DATA yHMBPOyNpsNr+Pslx2fTgXqAwh2u5wHIvwEXRCq40GGHAnRm+M2R25/fO05s/o6j3OqjfK+LePSq+ub+/XFS5sA0sb9urnfWNtEN
# DATA fd1Q+M70s2uQR6Oxj4GP2H+SVfP7n8NpW0cV/F7a3DDEQfz7z3BRPCKm9dPAw08PhdB1Dhgw3/0WfGTQR//vv/+ncKYPnxizjrEd
# DATA SuhuCe91PEAzpTHIO2i7sZBrbKhMtl7Dk+XzrmDQcrAfrS7NA1ZHT05BWT2CHkU5Kd7TjSwvpRKhG51vUqna61MbCUpX9s1gOHRB
# DATA 2nQreeY025BGp0ytYJJ2nEztdJo+8vXTYIpF6+vfoQ4dyOGPKuhGkIm2cL+FJU9sM15LHhjVyPxt1o9vPJ+178/L2DeJD8bjaUey
# DATA 04IYtiKryHpTcTwSi0xINGPIqVtllUtK9VuCsZY1gAR0NhpMq5kKmtSDiL2oVVma8qjdW6G9P1h+GHNSILc/l3vFSXfyDWrW6SGC
# DATA VaCA9ZA1j01EohLDXUIHr5+OD8QCFy8NuFen43Px0HCcJDB8w8E3sVRUirPYdNIdJQPY9vBg6WoexSi+vdqROQFMXTFLRYYThYvQ
# DATA 2b1FN8SoSR0i9EepCq1EuIBG3x9QqrPpcQ39KBBnCSRzGsGIckXsjzL1hnaNpuYQAJt4VEQl9wJORCf2wu7BMDa0jDvjZFpdPEsm
# DATA iweD0eLkJCgdBqluWM1kqegQcqV0BgcgQ01naCvRI95YUCHlJRVkD0d9qRJLlaIuh7SWypg81Jon6iXgrqPQJFuV/jy8lVGMZoWJ
# DATA cwYrQKE87ssNshhQzKnoGochxGL4xDmcf50fD3rHVZKZyvijKKUyM0WHeJxQu+DkzNIQb6VYW1BV3wDgzN7TCYPz8FwUwhYKofhh
# DATA mxnEhdQOzhXaWz07NFdprJHPSbSKdtofD2+U0ZUvge2AkPzPEkjWSUNuWShy2uV+5tToqc/H2/7dJ1Kx49O3KFj9Dh35iJN9+6mU
# DATA no0QN9iBfwm3eQylLUQNL18oiTGyigiidAuJS/ZMyMpYQ6JKzXgtjhp0uLZ0lP4tvhaJluoiOG66wbo0FsrxI/0i/UHSnZx0gP+C
# DATA BwWTKhKdvQdGvk2Q4WDFYgxQ0+bZ+ry4gMz61wSPkfXLrC8gW4DODVQYUgguB2sByHGCg0kEwgkgGlJK9VEP8IfZAd9gGX0XTrI3
# DATA Hg4Z8aRUwt0Y+0a8vVQS7IdoroqYa5rRiXu4wwAu/6mgnovqWq93Nun20HaxDNoyWjg6xafkVO3Iiz0vV5rxAEyE8cSs9ZOSbQyN
# DATA JnZWnPtOxHidH8cjK280+Jcbmkt/Z+zemybVHC4x5yrOInm9bNEtnL2Q/1Ys3t9DSOlvbdr+7nefBuSfhD7N/y0tsJkiDPIDviEv
# DATA fgtVgJkUnKLRA9ICelQroxDZ42VuSYzfg2sAIKCUTeedgyDNiQbkfZZpKYQzhDhgV1WPGjWAkN2oNeZC4+Fq6JWSMv9sLVfaCqhH
# DATA Xqsst0HtCgjWYZv0iOZ9k2XKWpllUrAYV7PUdszms0Rf7fT2H9/9Bh3cgYrSlvE/KC1/lHLjCxfFtDsCOvgQlIfj3jepcxk4wiMC
# DATA xYhPkOLXdme9UVtrBpf0o7HxdUN+39p+tr25uf21JakQMrYQGydnp4BkIuElDidwenEcWxGH2sGuqG81TeiKfCiLNJyFhNjWT3Tq
# DATA z7dcpe2X8cXBWIhHddnTQpSPqHGtXvkBNoxRYcP37GMpTJMxZqAAE6dNcbEA/xT5CmQz6tR+lKOZTsmCGk/q7S0MqcGsZHckVEIM
# DATA Cjjifwxn/TSb/32LCAPf/wIjbohX+rVRoW32MJeTYfi4nj0j1f9ZJgezVWV0MG0XGMz7S1Sr/SpTh+Z5QSlRhH9qNgZKAlHqHoEr
# DATA 4jsyAeTq/5eXHj1efejq/z9euov/fy+fDz9QB29I63l6MT0ejx4u3Lt3b5PzoUKWDaIS6aRWhnXC+VMpNyqihyOaF2CGT8ZnR8co
# DATA ESqpeW7DwHE3AYOA+nnS7ZGlAMBUUI8BWw7dBL0voJ00ICY4mX4hWOPwNuAFhAipvoOr1ZSazTY+AM+wrA3Y2NlkKNoqT6h3sk3u
# DATA bBFuw8axoDpAvMdoRTs8IPin9w7jCS9Qyk80qLO9voOu/kKSM/DHF9Y363BiwjnHhLekcpESRriwvr3VFIJYrdGBb43tTSxuiyGg
# DATA TJ2Mh+HCbq3xVX29Zp/BGGMMKUapERf2turNTmN7u6llG5+z2MLOXgPg8SGTX0adpVfLouXm2vPaLoZIoRaDMyf0x+cjVORgpBRl
# DATA aWNcSE6EzrnxLvgBcOYYjMRUMork4FDe6QlyHokHooUXaz/qbG4/7zx92cQmjbB5pbal9CyT8ZEY64QzT0zkTAuCAgg8RIouBvEr
# DATA HR4DqYghfDI5Dg7AxCbWkRiHUyqTFBk5X8qlUoxO8JjcPQ+YDGUkuMxELCmuCkrNzgBSpuEFVkbRkdsGr7cSEaKHCywfBUnLM77I
# DATA ahM76bThwiHaq0NO5w+qqhNS/6ALZSlsjPqOYhkIzRMNqYFhTHTCDM5PQ7NOQM1wxISU0q4AsId0k86c8bxR2921xW7nhSn/gJxX
# DATA VCnI93KS1o3GoBbDCFD4p+A5f8tqrBHWVgOWfABaeGs8fQbk4ESTGRW8CXGU0D+HUOvxL6pT4/4agOiKHsGJGikJoIoRhZihXBID
# DATA q9nIAi0baHHtbYVeAA8JZiGWVIwpHoAHCUJNpDbkZPyKcmKDTgXMh9oXChbeuZAvE4VUQHNaBgPy6wK2BBG01lXZqSj99i3jLdot
# DATA WbCN+ZJfF5aKOBUl9130yLSjVJVl4izUlyqPqP1YVdRKD+IypmTSYhQgRGH/9dJSaf/18uH+648PxZdPDtucjgjLRuIMusI5nHWv
# DATA eGKg3wXP1QdB603Y1fOINQFONTERKih+49+rdtQqraxW3DY4wxe8tGhGVLTgy4qF+cL4GZ9PK9Xicjfy76o4DCfNC2zHeCyX0tT6
# DATA cyV618vsBerwPGOh2icMdaYwPaykN1WU3Uf/SkeyFdcdKnbWk9JenA5jjrbSA3Z6jLjF7P3JRUIeYNjlKcOt6ojNetNcNWXlBjhv
# DATA 8A3PZfG8yYpXE80lblZG1BHI5QebNFdpLUrXfw+gNompC86tn8bTurxM49bCcau0vSnQ9BCgO0qBl3tydlJQlbawwnZu3YI5FGby
# DATA iCidxg+dM1QnqsFSxevy4c4VZ9kZokkRLC/KZ64/SE6H3YugixF1XQA/D+4tBQw2cK/s+h/kk6zhFZhKEylEVYOU9eaRIlC5kdRh
# DATA rCAnCpL1g2BZ3lgXQw98B1LY07j6IPKRdHenCFlvleWkUEz+eMDGJtyUKfGkR/xteWnJ8wwRAHXuPpZZNFtxu5QY26KxZPRlwreX
# DATA zLLiZ6FOpfGwe5pADgGcLfGQRZUFo51DQQ7JMTVE8tA5EKG3J7h9Rak3gIjwE+hIQ1KX0a68ZG736S3lSrDz3lCQgiUPGU6WUlks
# DATA iIUYv0T4GI6PmOmzpwPvuZCPENKAeLLdSa6CsPPpfGvzRlfWR+h4rxC8RHW6ljkSHV0vtRHLgGY+BxV+f9j3q1e/bmxvbb6UOlVL
# DATA 2Vr70fpmrrI1hVCgRDHgk+kMdBWXsaryEJQLnU9ldXenSk9emeCKZNilumwl7yO/X32Hgsc9gAOyjJWcMgsVQYxIbwjpQQ/7rh+U
# DATA waW0avWwz3H9abrsIHUX6ADEZyuI85jqIFA+HJG0UwhbICNQzqrp5BB38PCjl6WPTkof9ZsffVH56EXlo90fh+TaVz46oT0exYg2
# DATA eiXQOQTS0cAvaoq8JEIVURueTQ9LP4BoVHjzpBqym4eUQbhP0vMo/VqMxsSUFhvr0yaauahybWentrXhkmKmg5UabtCoUk8rrgN8
# DATA xviHDOtMtiFWtZaVchoS1SjPDroZzVuzOIFzFnM8MuVTmMHEKKeTRLdKsTK5LDKHGAcnkxMyA3y/I8ULBG5ZfJb5Vf7QmOIsjZBU
# DATA mhhvh+5u2uJzS5zdOoeDRmVva+0rMQxrTzdrYSYLln1JT80s01djw1wFku71762nYHqZz9FwImFFMOjJnuUTwQMYAgn9BgEzg8p5
# DATA /AYdJ5Tybqe+26g9L8hKJNZGZhTLHKOoTwBnox7nXjfrZ6gPS7FlG+Wo90kcfyMFmtTzJft55xVBPVWV9cBpo2CX9tBopgEn/40p
# DATA GBgfVBgO8r3NmqA/4l8wJk/R6a1wgDy7tUIHFlWiVYFiEyG19bkICMBUCFy/uR4GD8tm9Tm9iUd9PsnAIEMmx8IkLMEHGDUgGgTt
# DATA +wz0HnxZe4m3QvI81+N8EB8NRqOMip7Wnte35q4K0AuoT7DlI6CHrh2Ub3iTPC2EXPCZviuvOfTKAxW2GrWNtfVmbSMw+tDGPViU
# DATA aHG9gO0UsfpCHH8Ej0o0ppW15vmuBIRKn2MtgxadXluUhkIev6+rAFDHJzOvaTV4I1ukrHhFxRk556H86cllxWIOpfkyeKq8JA/9
# DATA oFWGpjA5mbxZPhqODwrhfanUaFUer4K+CAupUt6WEyGhpJ5+uKKhw2S685FsPEebgCAutirBk+TcNrPiM3TkMcR43NY9/M4Yb3Aj
# DATA IbMGVtEyHm9H0a0flA+trNWGND6I84bEuyH5kpHeaHt6my0qa9fJ3K9ytiHG55gORmfxgifQxUgPm83/52Sf5umI0FKRNsvAnOFc
# DATA JLjdT/aT+4Unlfg1GMf2kwfRkwJDwnTaBnpM+34kClahcPl+9Jd2Rlgw1pRfRBW/zkdzVuI+l0An54LUL5GvXLKUd6kDIy8BY+nJ
# DATA N/HFJWyZoCSDmOXLpDucXvYThA6Al2ktt7HlesYoyyVGhVfahscbpr/dv7cfhpH3UdFxUIhgDVHwV9VgtZIZoOTwVHrGXVMpQTK1
# DATA YKgaRBEZgzaj8Ib6j+hP+A1uMXf38AViA7gBOV2/QszI6hAyXzPSC53ojbVI+w38UT711FbR2ITaMgaFt3Gpwi88GZxEhe7Z9Fgs
# DATA 8Z+hKlEQSqtSbRNxHQgCiCeXYiIHvQhobH8XMGkm4f6yUbe5qbothNyGqKx1T/CsJ/sHFnGK67u19Uatebmztrv79XZj4xJTqFzy
# DATA ttl5IvbNS1Fgo7bVrK9tXq7t1Ona2l7zi+1G/cdrzfr2VuRWyo2pl4laP9mf7I/aD8Lwei8wW6ho7Sf7u+37T0Srs0SZy7+MwmKm
# DATA cJDXjf2D+OKHxkuaEFBZvw9Cmwby6i8ALI94vM1/RR0PyqX2/criIgxdsvh5pf2gQt/aDz5PjeHn+b1/vXyw32otlZ6077eC0qL4
# DATA 9/PS30hrUeo5CenVO+5Ouj0IsEZgHvVLrCcsCQpS8yLER0xDkNsEk9JP42J6uBKQj6N144NqsLzycZ7IqgS6DT4u4h4AaE4U9d1N
# DATA poTkXg6ax7FS2FqqO9JUgucIYbWjW0UZYPhYHrS11PLkJ47C8itlz5ySbhieAMgR2Vm4JL9f8eEWMtKLrUw5onTYT6WgLfANMoIH
# DATA J2dT8D4ONvERxKAvQj9Hgh1NscPgPUFOAuJnd0rA88G0e2SY3k/HyYCPyjrak0QeTGu+DmmcGrWd7d16c7vxknJzTqcn3dGiQr0p
# DATA qe669rNMbDRB54vOb6BN1Z35jOKN2mZtbbemoj2lWY+dVgpa8RTK5EZipysfCank7ABcahexxcU3uuGrRekZtEhz8US5dXTQdaP6
# DATA xvXSvzKc4AmnLKm+Cdd6sA+BWgQcOCAgBfBRX4363PwDlGiLkBpZ1FtaZwNhBQTyUg+uhZ4Y3XBPUGFp7YgTz+opMM8RMq+64fjJ
# DATA 3jsF5eRhpMwAIWwSJ6fjURKnTqB8nWSilUeP2ZMEjphqrmH7E8XBKq5L3GgCceRtNBOo2CQqYxvm8kVEvbwJxYilgO+I1TCqR/cI
# DATA lVqakgtOq6IEb/3sK+KQ+av9vuDp8h/gk90jJ1pzYrfZn3QPwdYySLA+zIyYKnQqdnSZK9YqeZMX57wO8C7ghW6FffE1ZkiyJIk3
# DATA lYyZMAUi/6hYgyK2XPwbPRHDY9Y84yW+qjV2hdSglG8TPHdPzwTrLpx0TwFRleuToOeQHUujJI0uCvAQ0Ony6serP3j4ePVjsmTA
# DATA VbETYZU36QuPHXXpQVBYKkZiHRRWgxKuDqpXh81a7jSVXIuN/9jl9elGTfgkA1CYNX4cIIzLGbBzH1mrGHGlJaruXMOw24TkfkxV
# DATA LP8bq9dC5PcTzfyL12yLBxzr4GFlT4prUSoopZGf7+3VN/hRFC/w65wr66/3arvN7H4l4tKp6YbSkRHzlLacfnGOUgUFXJnh/cYO
# DATA EB4nsAUDd1v8tk1k4p3zdE/zK8T3tnbXntU6O2vNL0KrR/PZNWXhlFUz7dWnx0xRkh4sA5qVrqH22EXD0uWzAbEMIlFVFVFN5Voy
# DATA jYbU99ZS21H6UbAomuXM7M7qiYj4+trOToeOUihW+zC+wNO5GtCbMHyWqU9Sihrr3YwQCtBD2CrXn+hWq3CEOASEzzePV6+kpoE1
# DATA DOlXkooAhMmlPEAGgCyzESoNeteHK7lE9KK+u1vfei4HgHdl0FIA5utJt1cexedcnYL/LQbsdVuU7tfl5LgrJA+UxvqDIxD9Io/v
# DATA WDbdF4X4TkrXCjV/5aB4y4qApgrmwk2nkucZMqS+xEQQZBdjhQzekoCD4B6Iodp65sB5BVHH2JFdcBLGBCyEr8bDs5MYHIFbloug
# DATA 8o5s4eOkisJvkLyJahwcepUrBWMJYElmzpTHCS5IGQlBE9H1K+WADSxm3tqVAiXtxi07KzfyShgJqWSlHbUNTY9ahmL2Lk7h4BUe
# DATA DEYmxCMBwjGziTTgYyXdJLtXdyBOQNwHVnW14PNeML0MYKtoyY60fdGbFr1zU50X23tbTWj42WZ9velJhsbVO4Y7nD2p95Kt+ijd
# DATA 3lokIrDRgBwS1LubXtIqP0VW/uuMB2EFsU9fheRS8GlHF0ExK4M+whGwk2UFzbnXzfvEU/cVCaSykiBETSz/vEoDvgLgbtzv8EZq
# DATA 5DCX9ugoE9WCA7YLMzBfQUkgjvhA2JD/NygQf0G9gXTrlOgWLhauA0iRBrxNBqCYMDFuVQAMB78EpadoejdejaIrfO+FjiAUEYsP
# DATA maMDt1DHkeoUgHdA0+NRiT0T9kd8DWFpbTje+bEufKSrIy8WAw7YKHLwuTu1qdSRGlsgDZVRJPwIQwTJf1xhaISl0mh8Lr5wb65d
# DATA 04RGKrMGeShAgBQhwYJOfnrBAqMhuRgaIADABcyzIXCsC5X3VPBC3NQ+lXQHMZ3dfjAF7BjaVuOu2LJxuJUOKFPEVIkHsjfOnDQE
# DATA lqgpZdO3EjAltia15WFUOi5DS48m2GuuYCav8YiLfSA25cY8cY079nAl+KxqC0DVYHXpk8cKs/xY2xRYN0o4xvsThNhBfRC454ft
# DATA 6E9IbpIpG9IykvLRRI1URcVkdzoDsWI7HdGF4SHZls2IZXGxnE12qog+4ugnzHOOag5FLmwr7QhvnCPMOt19z6is+yrmfqdUE9aw
# DATA 5NXHzzrxCTpknfSl/XSf0aBddXvtWtw5R7vj7T6QoV0MPQtCAHhpU4QTG/4DZTenUoK1yt744ScswtvabnbqW+IgvgneYLppqSai
# DATA mlsh//bAdKRK6GEBhy4mGKmmBDcA8zw8O15M4c6BM70v45Q8YOLAEuWkfAByY8RuwdNJ2gcCOS1Sf+uGbIkhCXNAidP6jVMOBspQ
# DATA xIXqsLeyCulHoPh8rlt+dYc7qJmrrRBCU/h+ODVumIt/8Hko3vUEOB3LnwWmY8sNUS1SwxdR0zX6sqSXugbydCJny0NMHGFUG1l+
# DATA 15AQhxwLoArHkcl18oAPgMXNNzdQdUuI6xjS5Z8hniVRpx0HhGGOYszOYjyAyYBHOuAZ8UdBST9rBhIsgeLx45WljDgVeIbj3rDF
# DATA qoyfZF+MqqDQZq3R2NtpWpxJdRnfTNRCsONCgqqofgBSuJlYwCQ88SpmUgN+XXXuQHvYEahmQgdgfHaApL9rKmDKMi6ecnAKzfmV
# DATA sV2lw6uZifaOu6M090SdMRIAInuQCQEUxt0eYeJ4OYy8iTpTg3FmBXPlyXU7G+Ag8HRv92XK//PCF0hF3sPp1ywD4uWxEN8GP4vN
# DATA FUjvHfkmw1fLBv7JcunMfhHD1Zl8OslH2Vz0HXI2pOkgzqxoSW1y193ZdKiqCi6W5wuJsmQcOYTMfjTp9uM59vZsDo8Mx8upxKuh
# DATA EsIcf3pRIVGMzzv9QYK4ZRbUUupFIIRQ9hPZBTRIpHXSHYnq+mTzQmKd+R47a89rnRf15w10McHXqTcsnpC5BuBnxgqgW++U/tmb
# DATA fO6dc/biMdSBvhjujPic9N5bzdl7vQ9rlokbt/qZ7dV1bZHDYRCy/dkvdoMNy67A2bU+y9m1rjX/8+8YypHNlb9oo4CAOgqz1/NQ
# DATA MVmPMbkVLWxrfZ0eFTMW0RgTV+9mr0lPxLaTXyOTYjNUKYTFmItUyDq1EsK8ARigAWBoQnMcWVK2XwspnlMghlq1RRWqG4y+9KL7
# DATA GpRgQANQwFXP4UNPQfmDSrnM9hikDnYVLfYVWTqFTFnxhNuHC4N+KBmtuASig9pPLO2S5ejhI7bCDbGqLMKbIZiJ42Kj2VERRCwv
# DATA VdOhTgt+d0+1s8wpqnsKTsISn3xK7TcPH1/tc0FfVNc1SDhjiVsv7ASayGAoAKi1hQWYZEtWuKGAcOsnwmux5htvYs6mHFVmHDDT
# DATA 29g8Z0cy+qdADEA/wkwvSwS1LoN7oKOWkjFthTmpNHIr7PQmMUc/oUQym1lSdB4ioeiAP2O9QG4bdkOcb0GkqdvuF7AUPwtoqWNQ
# DATA m1GdxO/II5BkRhjiopFrt2oOn965FNy3MYWGqBH5j323LLqq0dfyqxwD3Ze2Tw65FYn3rSTfWz9HvJX45ts8lBj2NjyZHKM8Ea4q
# DATA bTwBtrbWN+v63dLpV2nHlapKxLUBn9CwnTOb6A/BFdNcZtWLa9JULqjvbf9O6MhG9ynpi18muACHAhig/mBUNZ7cqH21tbe5iXdA
# DATA LpDrj/JNqZ8+EeLj5aUlvwyes6zXt1/sbNaauPPbS3s+etDQMlKe0JnSrxlHdTMJZ3BoMkE/OXGAPMEEzB4iGS4vvksR5EaCFa73
# DATA 7Z0ar3evwMGcyQD1aHvwgOZYY5a15Sylz8xVq/uxfzwHrQyQEdQNPl5yE9dgPoAOaTf5PUldb6+fNPB6SufO4pRdiT00XUxqWJ1h
# DATA 7B0kjI5uH1agC229kh5FRsYkBOfxKt2gxTTBAT5PX4hBAZ0KNEDPMO6KHgKc2cFkfJ5AcmLWWgD0DFDANB5elP3cMksdknngz745
# DATA l5UlW3CzyMNjiRHDZUx9JdeNxFpFDFvP3ilzaJFBmy+XTdUg1Ci/TXxltCLau1M6j9PZZMKRh/CMNgteM0Q0yqrWq0u+f59zXobd
# DATA V+Ll0c2hoh5i13J2rlFd0m43XDB9kFW4ZqKQC8JmyFg0KFem2a8nzz2QbMoNlSMD82aK2sjOjIkcO53CYDSKfUG5eB3jRBnugFyl
# DATA paO1a8NlHFAELC+mQcgtwBwXJAcG9IFHbvGK7i7Ctu6ng7MtWisgphSMDQkXxv2tp1GuVswrsMs8ZNCwELXq2xlaJnv8cnc3a5gt
# DATA qvN0Kn264bl8jT4DWFcxuN/xB7jqpq7dY25/E8+X1oamtPTS1yF99qY7HXTlLxoncR1LgY4mxcyj+c21zhlql1ns1W/InqXLtTQU
# DATA b6XPvKGlPa+DmZ2bhS54oxdQjk006+DOI2fbZdjzNQXuE1u1r2sNp6EPg+1RrDB1UdD46Vi8aHcI/Dg5Ozwc9Abo2AVxfTJGEUK0
# DATA QOsAo9IVB7jjQYKgNqlQdBOoy+R4jK6g8CglzEJlfh7GxG7BdLXABcpAuYwqJbzCtbczQ8DfHtkrH+FrzjNDRr05Snfl+UoHJp8i
# DATA Xbq+am2768/KrMf/TjdSxGdKIu9H/Z6l6k6p5P0OMMVMNfxMnf37Uc2bWvk/FRX8XDLubSrkZzgvQcC5VehaavhcAr4t5buhd7+J
# DATA xt3VW2ft6G/tdzYXNnmOznowOhz7NPMcVpoHF64jkQgBaO46kuNr6rnhvmlC8GnXZ5BcdCuKc+wFa89nk/AtK847fhu9odYkKjuq
# DATA zKmOQ02TVrHzkMV9Yr6sVsfe2LsSuoEB6VeNkfbv3xSl5maNNkAEtrebHI9jcVFdggWxH24/tfZJE4cAg5g79a1n251nYoFzfUDZ
# DATA UWY8iaeC2laz8dKsAQnbceBypon2dJgkncNh4Vrnf3t92jkYDOLTb27mivju33TiHsrt89vvf4V5uX4OPy0PhoxzkUwJWM2BmZhL
# DATA 8UzKbSEAQP9KMizd0ZWrytsYUViFqMJ5Qn5maqyRllldjd99e+0nWapqDTKgTYlIPxml0TO9r2ECWsQL1ALxIyEpd2h63F85mOdI
# DATA 0Xp47yuZmEZP0xv19arCiW3eyAqvVIiHeITv+Rfw1f7ongoByO6HL6u0sTGlXij4TB+FvO1G13L1kQsTDkiN2trGy/A6XbnWsewG
# DATA xzPLwZ6pQE2OZpUfVPXs3dDRyQRp8LSObCoVZQNCgboz62R04+Y/DJ6SVhnaoxS7iIt/0r2A4xZmXOoGoxhw408pS4zOs1RemKmd
# DATA VfTMA1r105VU0chSkgyUsIvVZbPBd8Sd/1UzYyvHGmSVq0CuTsgz97vv/vj9Pwa0k8peUzqY+fiuPsEcdIVkVTS2LsOKKQEe/dzY
# DATA NA6+L7acSc/ucoUl5J/2axE0Y3N0XtR3X6w1178I32aWObESTPKvv/tNOlvqf2GmVEin9w+UQjCcMakzj2vzmDxniXqO2TVfyPNX
# DATA nanzoXY92U7STj/5qYiimdW72XOc/A9GGh3XYXN2Op18/wK/ZcBONAIhcWaOIm+vrzLE5RsYdnK1Ue/UCP4hoqTx0YMwZCCIMEAN
# DATA ez84uKAY09PxYDQtBztiECCQONhBRcviKJ7CIdtTKysbIDp1XMTzjWgj6I1PIa+ZUnT2B92j0TiZDnqgwpyOaX/pybToNzLZZ9jj
# DATA OyaE/fxqUGM5zDR93ZgXpciffJu5ZcLh0JvSXOH1GTztfzIZm0xatnCb9JyiZVRc06RgAP7uy91m7UVnZ239S8iYIj2bxEFwZ68Z
# DATA 5r2pN2+qsQbWcefZsZfBqE8E4BjpP36U1xKO/6yMrcY2JRO28qnXq7C6kXqPB84NeHMSod/MP2QuCQqOU1LxfjJIxCAc2eA/KZVS
# DATA ZmmVA2Y0eL2L+IsFM8dluXlMKRGPXgxe10dFKwFmGR9CXkWPyvQACAzQmeKjiamcAW0gWHt4xbkuLmI3GFE0eDHo9vu83pOzU9Er
# DATA jARRD0aeZwC9hU+nhUcpm6SnbgUfJfpewJh77gsNCecPLfjTikZm3gFihyeiTlENqzpT5lVrERIiwenwQsaSiSVQRAwx56mDcf/C
# DATA xtXAQurE6bFHxKN+R+IKFqBUViECUyyE6wShWQJADJkRUwIqepSUngosiMUiQiwi2kI4b9Ob8ehoKiVuMGbBe7v+pvi4fjrxvf05
# DATA GqZJxMA6rCE/xsnLoj8zMD6fqEw4AC2eEW7DPMjzPlM0wgqAaNqdxB1GC8De8NsyPoIJSkwQCeKfpwhIjCcfbCHKtuzivoeUt7r0
# DATA EAQsad4Kn203ntY3Nmpb4dUcKl55upDZSMFH83mtSd62eIfUzJAvluSIMN8erju2AphmNG7sC+cPkZ2jfUpHkIDgUwgXQclNof2L
# DATA mX62eb1RWmyomqywTp3t2+3pUZzZUYnOmNEferIt4Z0W83HBCT8RTocr7y6CLHtMsXlEP6dvSzcfRiI4jua9fm8olPwtW7fckSkK
# DATA 9ka074k8nrNnO9u7b9u1IXJkRWEGE+pAAsc05261c0mM6yNsaRXmafG25qQ7Sg7jSakGmxvFCrL6jZ8WlFEeJII5DqZaNbcUfAan
# DATA loIugypLGyT31oiZcT4NBESaPdx3EPbT6UuU645hiLBQs0SEw/GZMl7oB+ACgXgnGBfPuGSN+NUA1QtX73vJ+ggTe/qWxImLb7Hb
# DATA o3jKP0+qXHn0+M+IKGHGPBgOOjTsXdCm5tQc/w8dasm+tEmMtmKF5CXdr/b8ZL9yo70hk8hJLLwj7/8L5G2rcd8TYZs0nbLN3AYd
# DATA Z8vU1uFg1TocgOnu2fbe1oZ7OHinalGrQ5+QB49SAMFyMn1LSd+zKvapPDWSfqcb6JLceTTGoj/uCHkQ4OGsM6Z5H3iCvwCpVaRj
# DATA Dk1T2mseSilEQOMRBdWHJGxc92MBOg/7rJ3uffxZmB22zJiCu9vrX9ZMKjfrszxG0ePGVD5NpQKKXHSKUg1DmOtYqOKtVgJdPzYd
# DATA E1hRhX86h2NMFoQJVgfgD8/JNYGOOh2QYjqdUGY9niToyCHWH34vr02OzgDGcAfvqExbYCHtCBmo1+lExpOQn6zT5UcK2sURnTd3
# DATA UAPOQMP4S5zPxqfTReWyKS033srMnbZ3PAZk4yqBHKN4qJ0mHWQDhEmXQadiKEoSCRPLytCSdu5ryDjI3EKkPI8+zbo/7B7Ew5z7
# DATA aGbLbwK8QbMrQLVpzn1G780pwbiU3AkOZuWy+AdKS/0ThKriZhqfDdjGuuSiS+6im2/tNZzFG2eU74bcSmhtK9hqyBUCtKKTKoiG
# DATA ynYorI4DWsgyb+BTZN7Ar2LA+BvODn/HmeDvOOoSHd3fLlGQiTMJwPtuUxz8hN95pPkXj2p+IynqtCDdbAhXt+m5GuAVoatFbE1d
# DATA V1RGh1U5bPmVmWssp0aNP4EX8eegr+fGh0pPemm3qmjhL+4+d5+7z93n7nP3ufvcfe4+d5+7z93n7nP3ufvcfe4+d5+7z93n7nP3
# DATA ufvcfa7z+V+FuPzrAIgOAA==
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
