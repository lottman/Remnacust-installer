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
HELPER_BUNDLE_SHA256='7d853369f4b744546912664d2ecae939fd207ec297a7f2ac1728f86765d723bd'
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
# DATA wlqzRmLzzvveH/59kP1vFPB/g/u/u6Cd5e1/UEX+YP//29b//QxrRQRTXx26mEvCm5T/xdJByWSyJI2j6qejEdVIY3rywxTvEbyv
# DATA 7i9fz6m+xfP5NFVfLn+WzNRnvOhmnAzV1yT93YsDXy0XyVjXBw7m6KfQX+PJzP7OJYMxP+Fkb/8Mb70ocpiVvGfHx2cHJ5icUfpm
# DATA +n3/5ODF0d7+q9OzwRcHz18enJwOvmx8A80Ojp5Sm+/78GmwrtXe0f4Xxyd0ozm5avGE2Hy4Uf50Uvlzbjn47NXR0+cHg9Mv9oDN
# DATA 7pbsW0BKP9ioeM8Onx+cYjpKKb/BS5znKaoqfrPdEnmnedFvjppgX15cMhYbvqMNWbo9cqw+5WSJbmnZ3sqFb1tezkA5PXcFwpk1
# DATA 8nodcOWpVscILQWOEvzdsY5pQpaE5jstV4wSPSEx4JzvlimFv4ufDD9qj1Wp4r3Y+8ngZO8rLC3fdYto0CNccHjWzD3KnSyLyrjY
# DATA qq4hVuaO4hDgKDsVMSQyRM/VFSdDvtykSgSuy9TJbSVWp/KubNuaHPGlBphRrS7LlfdFeg9ex+q25R1vbVG6EtWaUv8pf7qzaZ1+
# DATA wO/ntc0L+6fKx5VPSypGeu8ZB7m/QJiXQKWLM2G+/gBvSIjVdR6SqIlhnwVdHVkubapDNJR7MUr4iNhiOYPNizXGMbSCEV4pvYj1
# DATA iJIM0IH1HLlyTLnBdYoq3n3VB9TZTQONKt1ZK+munXVkGPBOmoSPjs3tV/DWX8T1ME3HZdMp/GrNRJfKBlKhTSfoZImwaxMYP1ar
# DATA yDs0xJSmMvPIiv8jv3HfYjzVN/PJcozSdBHPzRkl4bVYdGTqhNnoa1Xa+3KeXKYqg+fLHnLbWjyNOHsH2PKDOcaH5namIgjVQpE4
# DATA TKby8HxnE0/1YP8XDBI+LyqhjGCV8aGdVYQi4+ne2Z5fkgqK9sbAh/t7+18c+LYcoA2ivread7QXsN9K5TEn619N4zczvjfEmaUv
# DATA VxWZ9cB5scjSlXKYCCiz8N61fiEXMhodQ8YKpiEoEC4/4uWc4+XhszKzIf8T5kdCnwpih0bl7RyEFilXzuuyJOXhRmmjct640GyR
# DATA ikNpdqcTWu4ZAAQKdFMspjcI3noJuHO3jZ9huKq9q0yd5EBVT5kEb5LJcrKrmLzhkA8W3MwfLV/F/xeMbTrtgBXDMCdlOQ7mVNPB
# DATA nPG3Dp0jNfIA6QzWvQTEV/GDDJvFwcSMRVfg7crPdAqhLDOBPhsO7ZBwAK4gzx8BL9U6W6SpP8ZMG5dK8rJOX7fAdTLK88C6ZAGH
# DATA xx9g9Faz191+DK6ko5XxZcbWOTfsWR93jkVM4p54W2Irlu7QFmFTxSr+JgxX0rU67ui6Unj1XL118eC+ejXNlrMZZaOqHaXgLlX+
# DATA 9SUsQ6dmcvHtZW0xVI52q0ZzkPVBQ7LQogvH3Wov3DFj3SnZY5Weoqeq8pTsN1xbUrj1qUIuiaKOdso3pLH7wczLFbaiShXPTZVT
# DATA KgCfyllJGytGIq6eOSG6eQFrDD/Nbv8SNPzKX4rS+ZescX4DKmdFjo4+Qhw62EWgqGbOiqy1sMjFKjQSEWWktsjm0DuAnEu8Ax6m
# DATA C+zBVI/5ULhVzqwLNyYnlbljhgVzsjM5d7hQcNX9H/pOI6QDxbA/EA4slGd2Q7acuMM7OiATgKrbgRQmVsIj+BjT1jouilvBkkVc
# DATA KV4SyoCtVaUsmZRNdOTgW1z9HRZhdHpeV2fi0zq6yBmdLZcDPG+LzR65bEzSHler9NhngBwOr7fxnbI05L66siiJNAm7cpGwb6cX
# DATA XfGXrRaSFFinyFUziD9zi7yCQM2L+NX9fMB1uCCeHIbgRykXUcN9UHJEjLCaj3a1wNGYuP8886q2xxeLr2E9Ts+rLEhffmmLY2rN
# DATA R1YqK/Xm5f5LhNyldwu5K22KK0WtJ3l1NeME7ysF3FkXna4hfn3d3grZAPsy5zlk6vcQmSkerV8qSL5d6QA3kfUKbALli6qyxlKp
# DATA 2hvUakqjV/LFMaQUooFhTf0zc6RbVhL36Mcfy8wVDDs4xt3q8utziC7ozvE7SZnm9Hpa7LJFK2qtK/n2qgpcF0EVrX8yjKMop/Vb
# DATA SnXObpQz4znbMV+B7x4jsgr6K9gItkUnxjAOGpGDr8T3XKK5dd7buSgwCB0jkLbBepPPUY7UMKJcyFdk/t11xVXXCx2FuwLp87NE
# DATA TuKzp7Y27LbFKpIhq5pcrXxdsg/QgVv7HP6Dx5dp36fDn+4mae0zXOfD4zL3XSm0HICkcoaDcn3lDQfR3B8h8w7caWYrYk+pgHJm
# DATA mWYhrmE2dAomgcPz6YLd0nyHzSDJwDawTBDD5ApSFQeBiuXH8goblAekK7Ye4mpnMAcQV7f5RcxyjgjulEQkd1/ocuBnYDZKpV/9
# DATA Yk1K92ovo3miRC9jD2uMbJXMODVdeeSbb/I/P84DgdeMr5Co4LGUP+mCwsUa4cJCefyGfPU0M25SYcpSN3TcDLRZtyta1SydlRWf
# DATA q6zj7vo1h82rq5pWn2uVahrF8yKZEgYgpOxqeA+JlHS5mC3p3IAhzMoDNMzvKNK9WUO5hTJATjg+JAryXq3pKOWDRgTMWTA/hF/K
# DATA q/ocNiR6q/JHhFB9xIiFv+toC1UfBEG7DX+KjuVgdj8tOb5ftRHkSheLb2tOx7+ViZGhVTaPs6zMeMMNTCo3VlQgqHbruqK2CA0W
# DATA FLpqGy7qQ/bZg6476uVDrRp6yc/ZYwLmJxyJYs8hFUTBxjWZunJ9aRdb/k0RcUZM4Y28jMrzBOj7zQ79F7l2vX6humH7hR7gEahg
# DATA ehmjd9yWZFV8wa0naUlz6EhBgUE0padx/XKOcomdQu3tvbTOW60d1cq0M7cs6IIV2kO5pT/V0IHABTZYf6lodkKxO7F/nLdLBRqc
# DATA IpOcAaPdKajv6p6+PDg5PTw+UgNzZY8a+0Qf4+qTXqWQGEcz1G8FZoWWizmjzrLmPsiEczHBdwc9xoh7DCu03cT2U0UieLM2VdpQ
# DATA 55mcKqBrFtghHCJDU1bFWfXvGlPkcBLEyPo9lkxse1e7IjGhxngjd1SnebfkzlpT1615rAsNCz7ellY60ExcbL0dh7ff3SuAHNdX
# DATA 5e7O2nhl67YHnGSV3sEQo7rXCdnPdLHb1Je6K54n5ZBXXABq/R/p4rfcBbpn7e23bBI+tW0ZQNaz+1lHxXmN4FQ3QlJrtUXYXyCy
# DATA Y8BskaWY8tkYXiW+hTX8SZG3ZWyqzjWaHmH+0o1sXOZoXjZQWXe8UZz5mzf1Oke6TJs1dYAeKQLNSTV1cZLul03ge67+Ek0J7ONO
# DATA R073KQPXdAOIs9bde6gwzsoJcNO4KKSztv7io9FwGU9jddmNl7t1ddXnoA9S3+tuUOUnXU+DOgOoz/3ZhwELzgByCa6XoGLF82su
# DATA tBUFmBESWUDXfKkU51PiSAa79FauuqF6mLneJEkJd9gTX3IY6AoGgBd0XViqERXRXJgcJkMitYLyRfm1Lts+wfvrx4m+t54UYsw1
# DATA CojDUDkwlYSElImfMSw/St7slmpi4G1iFCSZ71obqLKesn5HZ46uOW7gFHnkMCHFtx/znnbitNtue93UVPtXW+7e0glpps/eqx6K
# DATA i3YIbQppot0T44fCm5rpSY0y05TT6C19qx0c/OTwFLaEfAMRfvDi5dnXd/eUWFl58n1/b0p3LVnBb7y+abYcjpPsirZBhrLe7AF1
# DATA v+hVkhV0N5unIVgpeBifyocsYMvES2AKfKWfr4JLKrEDiz9Iml7R7H8XZnQ/QwJKUcfdC3gT10Mh3BddEP2vy6oK62Pg5DUdri+Q
# DATA 4DTLo8k8kdsrzD0qH9mcxPpdIVe/ifTsVJYx2//ROBcfivLuAWkgC5VMu4JKMJwcWZtPFvPY2ky2r8FVPdZ6MoRIaMM7rzseXDtN
# DATA iV7Q4XowLSu/l8ID6UzRml06AK0DqqeGMYJSVetdDxQMyNcwuLcxYenRrSX4++jmSFMfBg8vyGrzB0obqGoGGpFULYIQaMiSrC1d
# DATA d0DU6HHxq4xz613HmF/pxC54wCULlNZLTSVNyDLQdNUD1lf5i6URM0isFlceLoTBtPn/kzMG+dTb7z7/v9Fothor+f/17h/y/7+L
# DATA fxsbGycxVqjys+WMLqyJI6syMudwSy3rAJ0CmBAaQeMQlY3RcmzfTXtPuj+l639Akv5yKPqM/uVWf0Sfq+edHLw8Pj08Oz45pEx3
# DATA PpAkJWDQ33B5Fc5rSbo1ThcLMOm3zAW2ukzMyk/5a5vW97FaWcbpr+DmFe6cS9PcD5+qXpP7BXq48/g2RJqwNderxWKW7WxtXYKe
# DATA sByix1p3e5Kb450zSQPOo7pgOO68wxd7n2NtwNwZBfHx7JzXN/vB5ogTcyre04O9p88PjzA/neKrKggyS7OEKh3pGw1MZl7pj0vO
# DATA lW8rkVpzEbXkMv9xiQKzqkh5vtVcmu3oZgoMoP5gPMBy2WUmd0z1TheUDbF6C4sur2PdOUSvIbj8vuXq1ynUGKHBh1zM8TDiWxTz
# DATA MQGFVysyYLogFdHqke8VYDgfuKXGuQ21bAFyAotwFlxmprrnJyvPn5Kla5qYir036HM8h86lxNnIvaWPSyTaq0yV3eyNe67Re3Fh
# DATA IwO6zhcRvrykYmbSXcLO1nz3Fhx0QIkJydwfeJfzExDvQ5UYzS2yBnAkugrXAt0PxlnKlEKWVSauHvg9CbI4q+V63btOwc4JstfY
# DATA 81MqqoceCe4Az1TRe9CR/1PMvOXfI+w4Ho/czopxXDg3Tgx38SFPC7B3UVA0SlVmtIgOU8bxhEcSLmrIvtGNilcZVyq2x2esY1pq
# DATA 7XfW3IZp0dYjL9lI55cUvjSXg9S4E7mOdN0dmjBtYZYWkRXdm7l25ufmy4Ubj+KX1CEYWuDyx6hGVknQDViZzGXHod7I9ya06gin
# DATA ZovOvd76102Sc7VJCohFT3vZukZGdfXDXb+ed4WecXFIZXQTaxL9DmR1EFEaCqjHoP9G5jYWch3sWnK3Nl9Oy+dSEhLL3OH0Lqqc
# DATA RCVu0TCYLfAKZZku/4ixBvWRQdmdgMLcqlcN4BUnj0ONmC0iaE2ZLO3Hp7LI/oIlgTWGZ+jiiaNMz3mcTJKFm91o5WjnxwaQrBXk
# DATA JXHbyKoPkTuDdcHZl+ruOr6xiq/pdIKb0oxjm2Y6t0k8jvgwEdbzhzd3+H2OmspYWM1vwLJFGcUJFYAX0iupSoUBlybUpcCdJCO1
# DATA 1CwxVq5vu5ynS7qBQM0MhrAvzVMv6tunZWwwvjBzMH8Fy9u3NaK9O0zN/Zg6d8FxVkT37l4ZWLaKF3KVTClM+zqOZwIcXh8AbFvt
# DATA G/rN0jjymwgx26yv4MJBsSJOa0jLOpWUwMxN9ifPrfWCE3m7Lxda98es9sEI/0up6G/VJVddICdJ2Mtm37eaXzlOnlSFu+2EYg3L
# DATA +mtw3ZuY7URuDCkXKTB41I21nonoyaWKdQW5lhkIAK7rzoOQRzmwNSmqAQxN6t5dzkwJa0UH9gqk3Urv4+LdpmqFLoBzhrm95zI8
# DATA a0g6DodW730sTmd6iTmGcx+myynZao4vTxo42mnBxjbDW7oqH9fFG9tAEN6DUt7Ma/GptJldycoZOVpr1dEPpx+sfivPa35X/2hX
# DATA b/qdoqKWJ1pmCoqA8eDmiXbWC0f2Ze6C5YmsP57PXVVjCO1e3xvQc5X1Ai7+4DXi3/e1eBvB+4iyTfTps8URxeMYLcwnwFN8KmNb
# DATA VexwBkRIyXdS/d3VKldWdz6hSrbmLvucdshL+smu33hcmM/SI071x6LAnywPqylmTWTWYboc8wV06MYe3yoVOlmsWxzub1Tax0UF
# DATA kN8K7He2f0MbtEIMT3T9Xbp3XDHYHKWUKt/GOf3BZWxt8+hDSuKy7MHIIF9mtKvsyzXtkdVaBW5ZAbZeV5beA95gJandwrLiVFW3
# DATA ndEXktn/wdyr/z78v9nvyfH7uPovzV6j5fp/671O7w/1X78r/++XElXV+YDC9+QiL3a6io8E1a1FKuz5Pn9vrm7Lve7fqv8SrMiX
# DATA aZa8WeMNtny/Uq/Frj/BB51J6ZazXOyd2c2XobASo/neNdLT7z/ITIlJV8vpa/LvLYCjj4PJMAp2nCMKlq1awRoZ+QgtQ6TUWOrP
# DATA PXLEzwsqZKiQN4eqFsElcNMMLDelusnlzTQfEyWz0tktG4UabKnCLHwZyKqZMobFLXxPc/dNdrGs78LKZpWrNTnJkCsC0AkC57FQ
# DATA Hj+HOd6nDL/7b+9+ybW9VSHvf4A/v33/8/d//e6fhTI33/3m3d/jFfbv/gkLgetKHgJ/Zh30y11BLZd/2mfqzDM5n/qIMvN3D86A
# DATA ao3LDKj0OBYg/80DM6DEadKt3wbnJUrrvtjxAyLSAAmUSYPnxJ/NRUKBLAVdwck3CS1nuMCg2pir+iwRLjnRUwtxq+lBswQdlEgz
# DATA 54wP955yHIV/JleK4M7x9XLAlmDTp8HpQplkamdBp3O7Jd7okCyshvLDg2cB3/0fCq9cz52w/pv3f0MkhZXc4ROWf3//N1QT/v1/
# DATA gcf/SOXn/xle+hc+MlhQQF+IxQKRjiGgHQPMTd0pywQUTKJuGwknmE/gw92DMP83LDz/GyTyd38PVIOw/IbL4mNZeqAUqzA91rt/
# DATA 988wlZ/D979dCy+RDEBYNdELgv08B/dFcUaYXHc2soJUb/Uod5tvYRPfbYI1tXyz+RY7vKsB565d/qyUS8eaKQfM6J6AmNXzzluG
# DATA Uhf+u1CD8TClFRvMOJzp4jxaAnUyyXrIppBzvvcxWZY2N4KFgGX41bt/ef93Bbv4F6ue6nvuXH8kOv5YIm4lvpo9fyLeTE9fuMnu
# DATA lw+dGjPaX7z7R/jyy/d/7eMf/ABkBrO7l2c9/tiLC7GpAoC3pRVXAFDxxrWd0EcVbfvgWcOW+juf9tqvaaJ8OwT/DHP/+bt/gf/7
# DATA xSPWmlgxXe5C/Jtg45RMJWuMPYypnrQfCiKyb5mnn2+YOA9sgC0Rn9lWlN5MkaNv0ZbY+v/Ye/fmOLLrTlB/41MkqQlnJbtQAPhq
# DATA qciiBk2iu2GRAAcA1d0C4ZpCVYIosVBVqqwiCUGIkC17PQ5rx57Z/WN2I2ZnHbv/boTcluy2pJYi9hOQX2E+yd7zuPee+8isAshu
# DATA edbSeJqozJv3fc859zx+JzgM+DnNzOFk9FJd6Nr6k/ZsMmBySl14z5wS8RVJJ1ROzz4QGJznsoDsxQgxcsRfMCH+yet/VH//p9df
# DATA JmqGf4npR36BWUBgJ/7m9RfJR/3px7NDP4C7XMsqxkAxrojIlUkEByyyT68RwUGDqV27duNS54U3AwzgJxWbhEVALZDocBW1pt1p
# DATA KPY5CX2A5GVNX+KrkBmXRH4r49RawY8io/xvyBB/wYtEOVU4B0qiForOiDozCdaq6GFCtbqhFLq7+1L0OhCWOqvO1EHYAWfah9+c
# DATA ApcPGCR8qwXy0L6WhQ5w7FpyAuGENy6yhgNnPc6uXcOXTlQMd8RIJZiBFQUP804LIl48jOy7KkysN4VD19Q7L3okoQnckk13g2pg
# DATA C7THcXaoGv3DFJA3xgCNqpRbUb3U4lO17dWELopvnBEQCgNNnvPigPODms9GBZMLlAbSyr31t6EIo+irPDMOrSDZTBUHKQ72I6X8
# DATA +anAJsNRzTEkO1Inj8mROxeqBbSGQTWhVBoZ9X/GXv+pGsjfgPig5LtQ9FSPPldk5afIh77wpgTEV/XVm78URxEeOlcjpDcGdrF/
# DATA dNrmOFkGGpN7ph+5WotRLYJisvvx+rIqFKN7QvD+XK0kkXZF5NOywGXqYDppKvnxHYfZo+0FMYhmJ7UTinU3mVlFuW+V8YLyXfz6
# DATA 8+jg1bhhrf4DyhW/SSDTFpBM9eC3r/9ZyA1AowrHSrtgQD+L5o5OpSYi40NWCY7m/aLdOSxGg9mUndHTRgNdsPAtAF0WJbH8mofW
# DATA DIQAhgUInAANKrC4AKYuNChEqt2h5ovFz9/h9v9ZEp3YX6bRcekRFAs1Dbztc2BikH9MHaW/ggxodJwu1Di2CBp3L8YdrIvkAhKD
# DATA JkiNTsLL08rijP56NAl3efCxhm2IelGUz7wiGk5Fc4RbXdYxhte4o+G506VDPVABIIy+S5oqtM8kh65nBwcXOHxIYIycAtTwF8Ac
# DATA Xv8DHDRBQQ3N/RJuNHgstQhTeqEhBofUsQxnQgzMptMO1lRWFF3Xknouv7x8n/lzNep/IAb75n9Sf38xZ6UtpJPoskTR0I6b4lbg
# DATA qV91iJhUcwquou9q89f4v8Cywp1MLeufk2aGDu0luA2OTcpQQu9pQ5SJObrsky3iNf4XrNWSh34zuT9QElu/a024oMEu0NWQ2mIm
# DATA e8e6cvScUkamZ/UwibqDwegl6QD9iavrqTS3/QPj98rusWsH544ngu67PZHmEW449LXgiwK3vIAzFmZl/Ac8bf8Ep6vs6GlBDfw4
# DATA Wk7LS8G6nPkiNDmDrDvCp5ISRoV5t12whI6HRj/VZ+g8vqxF50Xeq5Fy313Rq1ev3oce4dqocz7rDJDS9/iewl7yQ23bmB53QGPB
# DATA 0W3k4GmpKxhPXJ5gwKc416vFIwplATz+2sWiHOpFD4NRin5cgfVipYrg9R+kCuP8BdP+XktCI1VKHRqlC3+gl4oVOImAf+stlQw2
# DATA H6k8df+IuVBBI6mO3AIKqjKB5SIAUaWsqNS7BcxEYsXBVuBKMWE99rRYcaMC5slPHO+2aHG/U5aaEo6Vpq2537yOSoJaejgYHVIi
# DATA BLr6lPjvEINcEHbKm4mLMs7WPMbpyioBOBZXuhQXMGHTajHOsAZ+cGFR7fcipvkCC93f/SEwM7B2SxMjT07ZlYMol0MuchTnCCgX
# DATA EE6+3gze5DnkRNFqzSOeFFRgklaRENscL8IU+ey7DK+ddp5VezwZg+hi9Vkde/r7yEXuqtuqSmovvsWGharORQtrz9bLpkHXAb/0
# DATA PWmbI5tEaJxpkVz/A6qCTNtRr2qt5hVLRvh/EDpsngX52LlXcFRMp5pxcBQ/hXqgVI8nYyd3RIFIxGr9iur8HO38W24H7U7stqeV
# DATA 5f7EafVkZN5iTqv+zOjTGzIXT42IH8LuMhQp4L1+3UQDSmtmUZxcPPvDxuEMUFtKqi/y0nr0Tc2fGXOF1RMTVB3LZ68hbOoS0JB8
# DATA W0sARZi9Ypt4osKe0kYBVCT8Ppvje0zMaPe0UDeajVfqfrd2SY9JJ5vR78P/T4mL79/w/P/WVm/+If/71+b/tzfpDAs6lOpCSzmw
# DATA FCOD6KWCIzRAm5BP1A3WBnsrOgWS82g2pbKIK6KKgMd7Z1AsnvqtOxqfvn1St/4z1Xnza9qZLh5JrlO9TQYgchPyjPsMnLDBMov9
# DATA 4Wc4osSWQzVLHf6aDfFvN4UcHGTKyzJUjHIKYWFw2PEW3UZdmpK1LBoMw8YoUq2HSinbxKi8bGdAevAPM7YBT2A8d1tipv9E0QAd
# DATA aaG4N6yOkiW7oLxKHhnyQDKvpYNWJ7Ke9PqdZ8OREqy7pPNQsjPCzkxHSXE8emk2ChI53Cgozc64JxT+hjuGbd/qY7I84at6MhrT
# DATA 7nQiKhnAEaeQcnzJu4xOguOqH+iblnX/bFCmIfOyEmXOn41FtArgLfKn7D3yz2DIc1Od6JFRNoS5yXvCHvzf6rLwz6BhCxpCEyC4
# DATA qbhubdG0PjqdkIY7wu7Uwv6YaYIjhoiS7UCPcf3tel1pH7P2UXCrIH32l77bhbqOvf6d61wBfTZQseoGNm13EMBCeg3zgTB5+eQm
# DATA s8n72rA5a9Z9uJ7YyAzGORYTRK4Z6mOENO9MG7vtzUfbDzZqhHQ8bcM76zMLBf8oWR0ptlgOTQ9Obfy1Ii1w8x7h3TZXvxbZMf87
# DATA 3lJ/ruZRXUnp3vkr9LH5LeiQfgf2ZVgWdQ39tZrZ4E7+mzc/Jfs73L7/ifwQ0WD/6zf/MXWBINs813xV5dl2nCxSeJQ27X4EOFCK
# DATA ZGkmBP+col6VfyY/hulZW8MEjS/UXQvUujwb6gFeMQnSQj9Vv/0kIPF+Na0uVU1o0VVHoM+dQrluOIW4eQ8gewY6FeEqm6snqO2t
# DATA cfk4FDZnFYA9cjQCtbomOgWTuEB+xIZcBSLvp92HW99195PRnZoiOxsfhUXM2webOxVvd7fve/WXalwXJ5Cw7ZAq/Rw23a/kliQb
# DATA udiUcUfCiv4R9ZKP6FS9/z4ZOEoPzwUG9ndqv5Ny5+9xSL9M3vw5ETVwya0ekDpO6P39j+y/qycCPlKUDu3NoED6FXjwqkfk8lYT
# DATA DdxeVQKE18oXCeTvME4enfF4cNp2qR39A1FleJF32Km+pGCRZkneEJQjRqBDGhVkaaDy+3SOD+rwfLu982B76+Fn6qziL7W9Nu7v
# DATA be+YB1vbH24/fLj9CYOpyksonw9V7AhPh23TsTLWnDMvjjpqIk2nmEQc1BP9hKjDgbPDQ4KsLV6mIiZJoiIiSvE0UxeluV+QlyC6
# DATA +vya3Q1gVwABZl8nIL1UXMgQjlstrmhcexHQu9iswpQTNp99a4erJ4DwJ7At8uj352MpiquoKu8OlHTptMwxPOZKwf6KQvMBAm27
# DATA 35Mg7kF0QahXE7uJDIuUDphUL3mPm+G6nZm0serQRmeI7lzeCjMCCMMza0vrCur7yIpQ19I6mSeqimaUUslGU7ig5OaTYJAFwEHX
# DATA eAwAQBvxGXEkuugoyLHK6S0zYa9XqsOxbomRLAVVq1dB3eqZrNxZTH3mPNXpAhLNf1YU8u9RAkTXQd02fK4FxnCXZFK+szcOf4w4
# DATA z7aTdqbZDgvRNDA1wRyaECIoQZtqNtRYr73UUKDci0AiY4r5uYg8p4QypBJfkjUiUYwJbAi/JgdqazZBroKu+/+ADoboS4iiN8aS
# DATA hCJznXpYB2dY/isFlGaSu/DJfgr6gl1+aNxSGXO5fayuhfoWZ6KBgVS4XEd4anNhNfdZIAPjO3yo7tmA2sH3bvoIrWjNFcpBQ08o
# DATA 6Eh70sPFx70pqgoa0EW0P6pppy5WtMvfzNQsaCs1/B6ry/LL0aRnfqubxPyV+1sbT/GnUnnimrqQcXwJK6rEgT8jD3hiED9BjvCb
# DATA BBdSCSIctwSi+pu/RJPTP5dfQA2QmVVZ1GrQd4zV08tU5+HBXoC/fjjLAekV/jyadJ6d2DQqDjRS2VIw2pLGYlMF2CtFI91ggGQ7
# DATA H76ogUqWk3dLeJ3n+Sk/NVXHotI6U9V5iEybpH9S+04zfwUrsp88nR68l30H9oENtVE1cvQMvL7Walz7N6kko5AuOwcld41rJYwj
# DATA kKIajzy6Ci8IFA+SBJjyFDKatJvQfaAhLbMVdWVHg86zooVVVtgTuH74R2dC1omQMbvKe2ED/MqB2lWf84SPJ6NXp6T+pn44h7Se
# DATA PO8Pe6202+n1TlOrdzFzW/vO3SsirWhj+SBzJ5eqo/mtfScoyxZO0DWCRxPKoyxrGhpS8xO4D0fDwQjhq+nDJRfLCySI2dAuwzC2
# DATA Djw8XgIz+ZvSKUz3Sv+Fju1Q8z2RcMhFBOMtA7NGoY/P+kPH510fOt4hMCkn2Z/UnhbXEP1+gubbp8V7WW3/T+6ovVq7kwWwlMIb
# DATA gsbDyQzxH3WWcAFo6ujRdcT1o79vHNCOi1mQlCiG3HBVOKwOJZyMn9sc96HAuQGIB/CpILSKEJSQ7PGU6Y5IwDcd1EZx6rgvqjN4
# DATA m0vPUopEpUrgEf+tazrTNYXZcNzgKkAnOaIgK9kT+j7icDJE/s4TSlXgeTtDPRpW5cZ6Y8/fMx4WDdw00ECWLPsPz73LLc6jRqPD
# DATA bO3h3pHZBQtHm8g7dT7n+TtgKnC7BA7xCxQgfgmyAgoJX+I18xf05HOQJn6HvgqfK4nib9TT3yDTmeQQI5ETBbkjLzF4kYFLDIVq
# DATA oELJvHnz12k5lJ5JtwlwQPVEqGUCOY1YklEMWyUcEMCW1SeZI6kes4QJlZvcQkHK8iC/T6gcRVZm9HHYPVnlvmrrABFajSYryCyG
# DATA ucB1mnlsApsPElDBX+Xnn2OLTkjj5Slmjd7j/fffL28AgdjP5Yqo3uvMmr2+jgAx68HUoynnOrJqS/FZMfdEZmK6oeELBE0D+zgK
# DATA knWbjcMmwpuxDySWIKkZPuSwXgQnrZIpQ4A1U+c+/eVAx+7bvYbaXtshuBHgB1rr4YGiMVMhVDScZOJgBE/qyS5a8tEmERR++pPR
# DATA EG/ENKPq3jClbNxFRCIqCXPgeQIBT31uJn5fC/CwJOgLJnQvmtjxZUabhGSP/OnXL1LhVoBLiVrOYFmpLyCvQVdsVp4DN8RlMSlP
# DATA HG0A56Dus+4T241kbcBC+oRaud67Nke+/Gayd5wrjltME73r4DR1ZtPj0aSvTl3/Rc6Bh8P8JXTqDouzlE2I7F5jAK6djkZhzo0j
# DATA bZ7qD8u6gJqUSf8Z4tS23OOFCyK06Cawj9a9Luia7wUSGT8wXuzE/vLaAQHLaiG4TKAmwdNI0apF3dWopOw4b0TpjLgL2JrOVDNN
# DATA WrdzF1bRLn/5FpXkz0OopW/2nfIH6JQO1epDCjYB7BUQdEY/NA/dPOgCOzXlg0QQgYph/kDt+mUMQrUaEn6MAiADHfIjdTi8YFJb
# DATA iT1BdXZvF2cKmjtK65xsS/dSUxzw9YLjyJNOg8E7PQ8Expi0HMMwdiwTTuquvxEbk2tQVI+V/c3Sa6l1xddQiX0lC03GowF7g+Ez
# DATA tQDLaAefsXuhAysqdS/aKz6C2bjPCcK1WqKeXBO6FlCN97tofGZ8FPc9Ou7uajKJBQ68NpF0huRXOoDTWCW9PTAqI8TyM+79FVRc
# DATA A9NpJaZ2ZYLoZFwwoY+BTwWcgG5nX3v8Ho5Gg5pEuuO/adC7U1oFQzg44ZaebdgqKNQg8W4munn8rIluHEqeycfwR422kbTl6dBk
# DATA Y81zP6DX/j6fcBeaZjB2wAWPuDgXsgZ0EoghC9Dw0yKNaupKe4O39Ye+GOhJM8j7g5MFMoCVcxb+hEnCMrfdOD0ZpGH/ahUVYNrH
# DATA xvQVHAYyQuO40VHWL5EFOWcrPBwi4wistTCdRm+Qg4tKqLLX2jRXeV8Hd5T2Sa54pX4A1nSUUeVvYCr8uz9EiFP5iJzVFKeY5C87
# DATA g4G8ZRolnpVeyJOppt/YnHynYwzPk1UZzgBnBHhIjTKhOoX41qlVwVdai2uo/w913/oVWMjf/CXbeX7p3KvMncm0Bbcy1NupUqDK
# DATA c7EVwDhPNyyIg/9r61Nip9kR9dEgGuk65qqynxgVPGhMgdxqyQVp92A06x0NOggymT7rwrnOFvSR+QWhF6EyEwByDOrVb9EW9vfJ
# DATA 3sPdkkGp/T+a9Iwmmk06C1iNrAZe77SFp8R+YWYEoPmLad5BwwQI+r3OQH35djPwE3KwABXun8KlG27l/vi194jpkms3gD7vqneP
# DATA tJu56WcWt5fRIGH0Cw5wsfHB9f9zVld/WTW6z0OV9M/f/IU/alTZ49kXJxp+1gydMEtLP/yLbWSOHlNCrZs3bzBPezXpnEYbkcSH
# DATA hEv5e05Tm1SYW/uWbW7eWqA50848voBAnDN3Asjs0hn3sQUQXuxs1e2YztGQdGP+8v03MiW8+etk/fFm3VksgJ1gHIqfJ5+qmgPX
# DATA BYs8wa4LvIDFcWdC2tM51lp21ohZXpEQO/JMxFgGtZLFEGsSpUTOV4yW8hmqX16L26K0lcAtNcGBBTZmK5DZATTRN4zkk9EAJqNm
# DATA LFaOUcqOnpgW41VZ09QCVm/jQRidyiXPV96azsQEyEqfTBDmfD9VY99fPbhYX4LW5CzDWj2gYYZ18UqS3Q6OB5fMXK9JNZkuM66Y
# DATA k6oBCuJGC+ROy374xYEzGdWdMjxl/hn8LxbvJa6UrbTcNpLXf4dU9S/Rx+TnYB78JRanYDkyi2urIuAFfomf0nPmSj/nh78yADo0
# DATA JZ48pR6ivhJe0jKlehasENYys+EKJIbzOjw5FmgXTtH/g7F1fyanhjywEC3HuiSSFVSQosNO9/lsLPwX6AG5UPCJW3ZgEudk9KXv
# DATA OXG0zg0NHlkyibRVgeKtCSV08nNEmFatFUAq1pTiS6qmTj1R/wUnR9r+TStXl6RZP8eEYSAqmZ90GWqq66v6MT4GgNWm+oMkd8TE
# DATA o4Fwt+hHdi4QXCukX5d9RUUsmciBINXbll/7XL2aW3uOFI7QkwV8kxTb1l6o7vNOy0K40F63c6roH8XGcKXl1e0Ff+HVDF5+yHOY
# DATA emaBsE5xQXarpmXJj44UOwJNY4tdTxwKeiVOBTlVRshfcZRnptMOC9M7M42mupNOHxpYQWhbXBWL2oJeCYGO5mlbVFk2N6Naveou
# DATA fB+Kkfbfs83sM8oF6yyimi4zlRljRnPlOqQgbFMnjXkFZXAPLpN9txrylkYzTwCkelkaL9XY2w1mUCXqSVscpqNJXhzXdNCp6X3d
# DATA l2fqFVYBf61MSDe5VLWJJrXci7We7niVODrY/KbbkdcCVQhBhRfvof0SrKoE79wfNop8ytkMainnwSBtngt8gTZ9QJ/Aj5vx7O/4
# DATA kk4QPUszz+yDJRyzD31jEg+Cnws5xqSmOYeFBum3cY+svOhMVgb9Q4sAu6KYarq4q/L/ZS5XhmESdOvPyBP17yk8xMSpG59TX2Oh
# DATA LulK0viv8vZGgsUvMbZdyiyfayck9d//KAGjcI61fu4sBWUMEJnDPiafSDmpG3EkeybVae/mE0hCqMrw/DdLpwZZYafXhsznWggX
# DATA wGqgTB70f5T32ma77PMmqF7QajusNxhiLbgBRA7vFU11eUM6Yw72y+qBHG5kO51XdymyvavGCEgsYm8eiIzM4D8sJsqpOJxQM3T3
# DATA vJTsZkW7XERwuPNykxZ8gh8Y5AacbOupbXYQz6sJgvC/02kD8XJpX+5ThYj3wQuoL1TIDmRJrkLdA5wAswV9wf+r72OBsRB/garA
# DATA L8FlU18BflXpNM5H+g55WPyWsS9/RhI9+QWWzLWTGuzVqT0F8+j3vqGiB9Eq9q8TsIhjCTDzlnnbqa19OiIz68Cqx9eI19lzMiox
# DATA l6DZSkCbWk6DKbHMxt5Pd7kH7hZ3LCWPcLAWWF9s9Qc5qEspvXzlfmelj/mQm80CPyjCzcNe0lm4UOyNcQVGZfLPnL0Ctz9gAexD
# DATA Gt9ePv6Rs3LcL+m9pXosjgtnwjPCmZrS8G25PYIFaCy8jnEGKEC7MS2yLl8S6fXy3mPYoPgd8AGvBFmv1MZyhVAovT/HIlhPhNTS
# DATA P7qwAFeyajvSrYqhYTwHLA22/D+TKtm7vyNoJcZOhlqBLxdh3V8wmq4La0O6vl9gnB9goP/W6pcjI48N2H+jhQD83DHlQ0m21NoV
# DATA 9PYG1aYNhELC9F5gPcH9xAuyCx1tL2J3xaY9HPfS7r29ERaleN7S+Je9l+iDKQWnGjmhNsDCOuemIi5U864rtfgaucYToQsIbZEl
# DATA FaA2wXr5mVE5WWaAEOobD45O4yOh0qRal3AJVYI3gHnBGAG4pjqsW9BL30ny556cfAdOHgeC8el885+Mqz/o253iRqH3OVJ3qcPT
# DATA ij3fc5MT5qAu8QuUNyQOpvZej82stesuqj3BWYt4GXMrwvN87nrXSRtm+5AufvHmLvguRqYh6Q5NLke9UIhBd4b4mSCNtSBzVMe+
# DATA o+iGs+rojB33w7P0w53trb32xtaD9oPtR+ubW3CLkAYCMfLH61sbD20x/cbKNaDCppzhIgRHPfQmkbwRIY4GEr9WGwEOMofDQwse
# DATA NdaDDvXlrFT35Rrs5ZXWotp5d86UmPbkg/bjJx883Lyvp0I3hB7gYXyJi4ZX5We5PySHHDMv+642C+/wQ9S1oUz3svMiX46gexlX
# DATA zSWDfxTZq5GNI8we0X3DBXU2MUnBWhQyL8leSxoHPfNkyxgLs7AboUjkyEylgtGFOblucPRymPecBmOeXVIsc7+ox5crqzvKuoNM
# DATA LMicgM9LH6XYQThYusRp+Tq361nkVDUrztS5u9S8K4Oj/EhDzpQufLw0+AeXnAJcO7J2WOhQEYzaXHr7NuYv1FdBYV1Wadov6yR7
# DATA f7Hd52AfzUv4K8OtRN/HnNS41FJwF9JkhTxtdQ/QYZo9s0WU7gNjrhZEywM7JFIuHLW5znOTqlDtv15b0EZjBi47ocTgzRdUDxkZ
# DATA W4m0JZE20EjTVAY6iA5O1eJDZzYdpb6X9NubW2S9pQ5bMrMFD8sWNAY6z2kLK9ZjW8R5C1VgpR4p3HBL9/jSfkCBn9fnbv6wX94p
# DATA AaU3MUSe2Jxa26rerSjPtfC/wuzRcrTIihGwByL9g1IgmENavnEkBPfNJ5DIW9FU3uStmkPv5GHI5mxbQx4qm9kV+6popXWO+Sql
# DATA spaQZNZ465yqUj8ZWc1jyoLHVomwh2oX3tdVtoJG0M0T77At7qjnNoNNV49BRvEidSubFKSG/sTESHXmVaj7SNbYa9f4U49s4UxI
# DATA Dx7ppV1LIQ1d9xisTOMckqer3dN/oQgc/sxK3YkjJg31l+OfurCjj++JRN4H7TIMiRhYA30S4heYijj6zfyuCoIzJcmg2bFqjRJx
# DATA gMuhfgVj36en3HYpv84oMgUdPD2NDcU+ts2Q3CscA+pVfHJJGWFeRZcTF8pmL3YjKxME5DIe2Dhm7mW157f90r+4LTDWK60F+h8J
# DATA z6VWrUMdPXB1bdyqBzoRidp9jvd4z/QvmtA/sqU4YHpc5qaKXalb9+lyYvec4E5rXYwJ5/MXo1J0/2byEAPpCUFyVnCWbwJQSYtk
# DATA PDtUI0qe7DxMCKaMkpdwPDzBwqgZnuRF0VhMO0JxDpBVb5IPKCnGkEkAb15yjyoN9uPP5qD0lKYcKNPrcrUeqPCwN1a8RdJHuSN0
# DATA XWhW0vrajUdb65+sf2+jTXoaNXXkzBnTf+Cy6EYyB4hEUYYFR1S21XlEiN1i/r6wZw9/We3cExY68NThCx2pSDVwKY1NadMFmNFz
# DATA 6FNUP7kq8A3aZhcEWYohLBmWZyotAVuKEljzUUh/4rTcfnAQ8muvNmQk4Ptkot05MMp27JuQygADAm0AY4GYDsd5f2LDTFkoJtyC
# DATA V1PGB1Gc+5TpgI1kNfWAmYN8LsH8YB4vG+BRJ1YLk+JSqFYWm2c91JcTRRNsHKPnwSQzVVEQohesKSOPZdDm3DhFwsDnYBSnL2aQ
# DATA KV5FGPwL/nbCpmLFDEwSIeozRHFe8P7Q0+8g9C2wqsw75VjRV1evJrl+G6UcpadUZ25zikKs/C7zI8njYY++VU+bd0zMLon85cYe
# DATA o78ROrrMhRthMxoK3jghDLoaZiiK99EMgDWSvnmQNOs01XAL57cHsdQ+RYws84YLAmXBCXdsQli7+bI6pJNcRrv28nFhfhzO+oMe
# DATA Bwmr6wWqVcAcXIEAc622ny73GJePp4lcIKlK9D1CHeg1ykHkwpd6ExRw27LZikpvxMQ7vdOq6FSd3ZhdW7V3cQ2V0M0QENLidzdU
# DATA N2r7AKSdv8q7s2nncIBBxptpFEsb/K0omBp3lmmpMVY7L8OsunodUEO+PCYbIRIo6AxQCci9gt7cdcQKH82mrRurq6xAptwAooO7
# DATA 5s8NNwnARTw0pI2ePDRkKGDy+lfJx3t7j3eXdZjOm59GXYBsIOEXGoOFgHrZuegfUc0Cbki/VgcRgcLxMsd0SUl7QLYkMi67spcj
# DATA 3RFNIkfzA7olw5EY5DTPUGfeW4Zq6b7MfuhZFGyU69Mpu60P9ToIH+5nkd0Ucb22IJYLM8kFLRiS8YmgXPauR2flt2eDl2NtkxPa
# DATA 4orNSEKUujYRSRUGPcwRhOPwOcUHNCKKTnLwWPm7FYN1gHlmigZNuc5JGsE1l1xVc0OugivNHO2LgAVx8S+CC4Nx3bXmZaogAhrE
# DATA w2BUFwt2WkSgIqjexmyILksn/QKuTe3Rc6+60KfEFR6omrqABmI0IK8TFiWorvt3Qhi2lIAnAvMrDo70ncos8K/t6lwJxI1lsee7
# DATA 5Z7oiHhE1nUSh5jsq13YRiXt4oQlaBVHDOxoTpMiAMA5adpdrYS9cXvkYpMZZds8OhAVAhx5CsNq8RS6TUi8Zh6AUHly6Pvz/FSi
# DATA 4F6QFltoVRH8Y+Zxkfh1DijTanntR/5P6FwCXOc/OKr5r/602ot8gK3FB1RieLlQW1ygWpWpG7jS8snCom6+QT4GB+cZ4/h+Ng/p
# DATA uZHIpNTar4e9hACJ3zjuOWaRSx8YR/a6CG1xkYexC2xtQ30g2ZA8Qupnn2IDQwMUtu1xp69ZZGB9QTZnH9YJL4oKO/g38ywInr6H
# DATA JDqb5KQkn1P5stsETixTUToZ3yefQ7eGyb5vkVByunf9b5AXSS2LpHdke/+UNcxnesqb3grUEzkHHF2BHF48zhrClV19oeZUlgSY
# DATA VFniPLhJLH7YdcpLursbiK/ILDubVTRi7v1Rpqh7hTJV3Uh5NjmDwxCykmuPhqq7oi/UcQIQik1R8Y/FIi38YdciIFxUUxBbms2Z
# DATA Git/kWFPyl1118B/0arerg4jjbr1BFob13HWETcPGM9RioPlTfsULVaSqvfkzGDEFYOgVyAH0/9XfBXxW9uTfJArwusxq9jgtNZF
# DATA GyEdGd5FJ2q6jD7a3cxHNDqPIsyx9tMc0ZDMNMtw4VjHGYNWKEX1Q/FJfuhgLLifGfN7OVAc1eSP1Ci8vIn1y0WrpYRYqECX/Syx
# DATA WJbNjakFPSf4xyWmyv307SZL1/XOpmv+OasSt8sQ5RbURkbkC+MG39K+vs3obZnR6CDsBm/A+k7sqN8wIw8aEVD/i9XJP2TWUsj5
# DATA qvXDK/m0u4KlVqz7PJbp9DrjKeP/eY718fvhgtqG0lxVjjLUJKzilAP4oybYk4xsNrITS1fZu5pHUi+4ygYoNk0dXOPIDTRY71AT
# DATA lGbz4u21riiI/lmcbSyqWwoYmpWKjLTnk9yoXBQTeYT/+YKaq6Cm9qBzOpphAIvDyUNes+CBDPhNKWuPXkhgWZYWWwoWyz9Q32/g
# DATA n4oUiyuro6p0b7ImxYyh5QvlmHlLyDGT26wM4MMevWYUtNNbkBheoQcDYmBCAiShbCGXoncD0oN6Qa9n6m7ySF9KFnHMJF/DOiOb
# DATA POqM5R1kHiZiZjK9UeJfVOwTOWkuog/i66JZtgPPJzKmL3L0qM1wS3eUoInU2HZGXviyCuW3ZXFXDIvTYc3Rrjh5Grw6dRKf+Bhp
# DATA SUVqFSf8xOUO6kEtXemM+ysAfrxC0Jwp2cKhDdoXKxpEaAyQD+TXLpKpNtDY1aa3Ne8d8r2P1YwP1LszDfTbyzs9RqjGqT0ZqYkY
# DATA DfvdGijM164TXMvLY0BmDgrcNZ83y9NfU/I/7BJlN0MvLW35uYV5ABW7UjMXyzYtAtv8lXGFN+PfUCJsi1ULnA3UBMc/Ohz1Tl00
# DATA Xt1T1ITVIDkn5+iE2SrHf/aw06FeARAQeUt7T7cGh7eq9L4tybu2XzwcqeOzDg5GYNipY5BkBV406V6smga1baAkQ8vWz01WHXIe
# DATA 1rlBfwr5Rn9LSBcQz/o7jJb7JWjiIoK9twbMg2SS4AbY4arURIQYTugISvSd5GEWKnStUoxRlUogp1BaJE+ebD5o+HIhp2JFfytF
# DATA h6j9Lofe3Vy9mVWRhcU3X3zQte1dTngu06A7U6GGIbMCW5twYUNZ8EgWgzwf164zo4yrTtG+mXAk42+9+GQKY9bKUl7Nn7z+R/X3
# DATA f3r9JZtCAXeSIEtiaXHDcMlfm8wUGoyfzJZvYf68IuSc+fr1/9WGX//yzV9B0KefOwNGl0Z0tCGnK5e7jDX2axO8+sUYMAJqncmz
# DATA wmb8gl9AXzn/c0vrqFNP9YyfNcgehX86Ol98AlpJGxIUqVj3Mo103FRfXYWZNsfaQxtkwSrA8LNMzFyYra01TFRDM4dQeyb3yaRA
# DATA DqoTqTfWJ89msH0e45uakG9b7XZv1G23M/FlAzwDO/xJLTU9S8HBYQR+H619bRkyhiENWy+t99p0L0aDCXePRgYdK9aguikC+F0d
# DATA kZdbjynnoOL0SozrSfNi/FsrqTjddXIE1mNCbXWXlAS2bKROW++isTPVlcPlcPmEembrLkPYXaAu9E3J7pSVYXhaLlZVm7qr64ts
# DATA Ctk9cc+kdAGfqqXw7Hc61OtZvtxH8dzik8JuTT3DAlsNnERs0W6AUGmDHmD3o0culsV/oHRRyxyKMRy5YIQ176ABydXbGPghkYxK
# DATA vG5uMicy7EyPi8CNOD0RBG5uLxH7NKFGKoid7qQESOyDPyyDquMndMd0x8C/aRH4B189+ZeNEuMHBo1B/qZgYPwtkY1DhHXMCOzN
# DATA fVZO6igMTZMPSTIkKRHkQ8JCkErrqDucDhwW5tiEPXpbmpYYNUboAkYZumqp4tiqKxlnKL6/s7G+p/MR7zz4ZMfPTVynzEi2GZ0Y
# DATA /KiHDcgkuenLFK8G0IIrAOFoGkfwogb/qfOTh9v3v9ve+NQVO11uGQkHpV2CEn5vdjIuJOGfu2m0igKSlRfgid0puv1+i/0pwRw1
# DATA nLauZ8CA1MK20XWu3cb92m7Dfmu3U+uHWvSfDWcnuODwZ2fQ2N38aG9j51E9sb8/fvJYemnRc/qnRhWYlHzX2uqaj659/WlNX04c
# DATA QYc4opRLalIcNTLqd/NTEkUjUjmJX7unigqfbLzqT4W91sNFy6mymhaQ7rMDO+5zbskT4zIdNvf676yoai4jRm4NXCai7ntzXPYQ
# DATA pecnmFcdpN/PNSDIrzDN+hcIufeNRf530pn86FAdlfHpN76y/0HC+ts3b+K/6n/evzdu3Hz/tn7Gz99///btbySr3/ga/jcDD1nV
# DATA 5Df+df7vm1dWZsVk5bA/XMmHL5LxqWIdwxtLV69e3ck7PbXFcXuoa+n6402CK0L/ZbysFsn0eDKaPTuOxQyp8g1VyxKTdS266t9g
# DATA SoGDBYe0N9VP1W0Vr4z8U91cjtUdU/8Ewqf/HhVL6F8Bdw9VRHMPEC51kYlpTBEW/Se0qf+WN1jvmdNXVzllns76PeoD0wjdB7xL
# DATA KcKmLoiKlnYHakCJMSHShc/cpoyErwbNV0+TBph1/4pRnowhsUq/p17InCfkbYE8j6NqrH/2kvRorM5njKGkivQW015/2OgXnen0
# DATA tBb6hLkjSB+R32Mi4nlUtZM+eGWT+DgaYnqnDuEVn+jvm4kr/HGXeOkb/G+Nho1kmUZOxLU/HM+m+qWZ3q3RTk5aYV+TCLoE/Y4V
# DATA ijw0Cr+gN20uXgMRHS8nilGPQcMPctNJ8UxNvzoOasvXIbmbamPu/EDDpn71xw8w9/wdODh4XI4ougZVOhDRZAezPu7bHrbb/WF/
# DATA 2m5zz0gfOXquNkLqAJVY/SrdEE14GfTV8Wfm/M7aJ/CMFL0GN+DcaJJsPBqYm9yU127Ca8oKTX/qrNBRJzlvjp6oZx07ByhijWZT
# DATA mQq7npi6dc1pfDytlkZ1QE297b0Z6Nr19xur6v+twWAxgzCUgR/N5lp6vkiPd/KT0ZRpXaEvseSQT0vbSSg18e7ux8l0NoSRwWGA
# DATA EqmMqBkcNXAt8S9cUFpBk9V5BURVfOF+xfsQvb0+Xf5wNHnZmfTy3vLjyQgc7BK7nPKt+gve2Rk4p7mzSR0WmCCGCz93O7SQfl8c
# DATA UJAw7fmTx86gMqCGAHTF7PwK6d+0oMr+1k5gFCaMEfMCPoljjHAUkYor7Lpz7Zqcx3MHadQshrsXuOx+uk7JHn/EgeGgU/sgVze2
# DATA CdI0+7mfU9b3LUVdfWkuQv6o5h9odm+Fj5EuwrTQmogrAb7NGlw2i4/jPiUhXt5jOFV3ol4tv3z5EnPuLZtWCc/YthjOrGOdhoTb
# DATA ikLDtppAkGDthgAsgZP60cYeGxDXsgW8QtVGCXfYjtg9MD9gqMKtAxPYgv8Yst0y5NtBAAnV/njLE/uabpPIELQZ6OY8O5Cb7dq1
# DATA wty4rm0wwhRTZokB7FeuKEvuJf638wwkPvECEU73BnKQqrvX5Fle4tTEbNlJ7kg9ibnMXsguYnymSIKIGjSqDGPucZI1evvLqxlo
# DATA 3M3r364nt1avw39uwH9unmMxvWHvJtfjTUvrhaIh+oOsdPWDQO15C4ObOTnq9Ad5r4kcI9HOonYQmYzViixELWqWqSd7tHljRpqK
# DATA yfu9z4r6ZJijkpIn5g5YysBH4EQV7SaPt3f3YFegd50fxAadU7e7kzGF1Fj7Q5iruYbB40dqo0+dhG465Xpv2tA3FoSi86quQwF4
# DATA 9iPVemM27ca0N6WV9YsRJTilyho613z6fWC9762uNldXPQd7qqsx/REo3+NhSqY5LqtrpW9a0Q47OdkbnUKXqPmlG7bPme0vd1V1
# DATA +vvClDZ8kU+UHFqAv2zxw1mnBzLdaNqh5I+AjtHpD0nVbtxo4ebnsHjO7Qi1kNFYi6MCXYHvMhM1q7PBAMGpa5N0f335+53lH60u
# DATA f7u9fHB2o37j9nlKybTnyvBPtMjbG+XErI/6U5TeexbnO6F58DbmJFcfYnCNyPnaPumMUUChOxEIKOv39za/t4GadXXzUncn8JNJ
# DATA H2zurn/wcOMBymH9E3WfxMcPNx9t7tHT/NUYzCfwdOPTx5s79HQ0bB9T9iBbhcnnY+eOPTYMeL7t3dwZGT4fjl4OtV4g0TUtERLF
# DATA CQASqnZ6mDiZFp29kRQ3bmMBgh1bzepeCfisPZ10jo76XV1GLutqcrdFTcAf315dfX/t29++fuvm+zdXv/3tNX1rwVLYg0iheaPb
# DATA HKKXZ8K9UHt3BjfYwiwi+NM+O0XZLDKyNuzeaVsXo0GkwxE9T7PGbDxWsrCFxNL1mRvK1nZ7Z2NXUV+1lg/WP4N/PtnY+C78+2h7
# DATA a+9j+OOzjfUdeVkpW6hCtTaagE8yNp/YbpGbTGcChw4D5g+CHgEXwIaktdKM3vbzjqlHo3njZ8lh3h1BNL4pKI8B5y6iHbcPM7mv
# DATA t+TBgdyt9jF2yOxuq5P3G9/ean+8/fAB1H9aJPoM3EFD1ws6rsDXeqzINTc4yMOUv7R0xBIoMiIbGkU5GWG1JZTG9/PJSDHQzrBI
# DATA ICwUDyxjaUhS0Ug2Xh13ZgU6ine7lHbhRP1OqIGED3jDueDCZr7X8hs1B07N5prvLsLzjHvKUhhNPs7jgUS4MKZQhZ8yNbtM58y5
# DATA P+ktckXuEc/Fyl+yHT23NOkJpsbWH9+xyDHJ0Ww6w6UaghmqSNDP1OqV5PU6tlWt0Qq6XbGHnhTgmENJW5RAk/xILe4dJS9P1bWe
# DATA unjSOU1Uq0PiBZ0Bgh4kxRgEfk07Os/Q+3LJYcVnlm012TlYb3Gd4trQ9nW4wFo5g84DvUop74SlQfxYGyCuK2K3vHZ9+cba3vUb
# DATA zVvfVv/3/QBDIuWePoTV/ADCJFV7TMKdd7uacDTNxIKTALKwTaCPw85gF/g6YgGBuIpZ88CPqYb8PssClKtUWK7A5diMRJFCBqZM
# DATA Y5yLtM+9dmeaBmLavn67jk6NwdyJb0Uurz5ihtgW+Fkqs4XMBDFtgUd4jUtlybJa0xcDiIDEWRv9gIzixXGnN3oJEZKFGIat5iLk
# DATA ewyane5o0BRngUUu1LoyIg9pn2U6cf5OSV2YXKSuY2wh7rBme02Gffz5RC0c6J1qYiha02cH+Fg/wZJyqF7xorBFXVQF3TfN+ng+
# DATA /fgN776gFd5cel/XQm5uNMrMzzMQiSys1mibvlk1pKtyFLm57Ky5LeieuqeBriEyBIT7+C2UbdRtn0rArxvXF+nzY91Xo491RFUp
# DATA pnIAi/oTRdVJzqnYXNLJR4mGCKcoMBUESxXv2dYoCbew1OzK/CFC6neQX8q12laWFX4/bfVeE4+sgXCVQp2qYfDUn/vLawf+Pqm8
# DATA Nqzdrt++CfcG1Vy2yMLIOGNS42p9XycpjsFMBDuCdMaD/FmnexpxDuUJDJcnxSpw32Fw5OwwvL7VDWczLmWYrYdvYmCbGfbyHo/m
# DATA m8l9szSJEorUZpmiilI7aiX5CzWGl8c51X+CmhvkwB0AgQIvIJBg+EKO90eiRP180EMp07my2YMTkhWXciA11aO1/LIeY2BlnOvA
# DATA EEWGoKZeOSSJ3+h5ISuC3mbgZghSjX6LeNj+fRsnHy+tBtw5yr6BP2Ft9rWpVxYJzHa2bjU5/WdDZEdnhZpZ2gmuaqNwchEW5LaB
# DATA kF3m8ESZOKJznssNBRzP9jD60QESLd0tG3ejyU8bGq11xn3n6q3JpHqutbo11D5BYB0EGKCZeeXwdFnvHQxHcGgCiGQmTqpzlINh
# DATA zJoJJNCJNX1KH3RjJQ3zugtdkloWtQfbxGNoHCK55iEcLR1iUqCeGeVFsO+gZQdS8JItA+bS8ujR0VGRCzX5aj1ZIy8It1INsDV3
# DATA rr5DNba05pB+IqDQH6FwZ95Q9S5jQxk3DnqDrwg1cz/FX26WNucFbm78IowBgIJWhYOoNJDmYTGqitPPzgcahlRd5tAQjSt0h7SB
# DATA +mEnQfS+RN27+6Ne6oXQgVctw4/uc28OwpDMUOWUEWaabyYq7/eDGRlLchbFqGmM4isQxwz6YPLGefGH+RDcJ2uxfmR3aC703QV+
# DATA ZH4mRSyBIcS4JG6fD5VQ/Nxnhc6EQDdFNfditZSpU7TXnx42rZHl/KLeK0H34pVuYBV8BwWldw7GKdZpoBe7A7HN/k3L1LIO3z/j
# DATA wTX1aeWN26Q+nDsUA4toXLTZ0PNlx7g0coOcTcezaVk+uzJ7MnnDmC6jNgDW4BBsyaqewxF400BtaUmiYqdxRddGgxfa8GfKMp6E
# DATA zE9eT9DHWQNX1RMfbKJ/JL6Xg0Lf2uFpTbxVvADqzxZRqapxqRt8AnaCU7jIOBOgg8aKRvdYdagmiKzoGm+nFvhK0PjpSdt4O0jJ
# DATA VxRzOBLY34W7DQHN3n+yu9def7zZ3tv+7sYWENcdnbgRfaDIPJyYhGxaRdxyqnq0vvP9D9a32k92N3a21h+h+kXrTDs9JTypGoxL
# DATA j0hGZ8T4eHWP13d3P9neeSCr059An8TkGKcC/mlYBkhohmdgX1awqDkWrJ7Qf8o7XdO0ds5WeeSvIBNA6HabKiK+gFf/AuNmrQIs
# DATA yrj6LEos0ycAZWHZ837a9yQNeRmBbWjln1ZL+zTTF22s0Ao+VH82Xw1Mn1N5e6PC8wL19GSWT8v01VhdMUHfu8Umxv4h620X/R8J
# DATA YLU6WSoLFhb2rciq2RS2URG8OO6cgqG2LlW7rvUlMjn80Oo7tbewvpOpuwVcy3yrL0VHuKtLMp54UNd9ErL/QQCgbCqT8peGXdOX
# DATA Fl3IVJktzHsFJcCpJNgvsvT3+kdHOcJ80Y3gDjY6UnMGvERJvB43Rrdyk7yau4LHguc+1ZOvHuo/ZThJMzpcgVOt7bjuMNzQO+3i
# DATA XE/AgaPU2xmrw01lu+wdcF+goMzZmEIpmecb7fZQ6x61DYVJNE1rel7KoCVysmXLdCJS6j1MGv6hnuBGxVyNTX/nnmulHtiVjlhQ
# DATA aCZnVsg4B+mw0ztVD9UNFmMqZ/tX9YJcpQRHM42qAMW1bpfSU3SVeEKfzvkMFHWKbU8Lbp66n52nsouovEGvQCYblA5DVdE0hn+b
# DATA u8bwZKprHg17PMlVD54dT43dXHJEdV8n4bmR7KDlI7HL4Aau9CanbSX0+DEI6QO1euq5CYQjwzyRwfDouKHtJqjkVBFWGDM5dab3
# DATA pWsxGvOnx+qQQNe+gzs9UR8Am0P7wikorP1u3YcNOigfL8RQic6w9AGKedYOgwr7AJWivOD6AU0j/rLpYBAZgtddXtSQGIANlPIK
# DATA MZk4uKPN2BGyWE7XLdJhNa21LrURFMPopa7U3cqToEqEBzqsliIH1TAtc/dmvLVvJuvWNwnsK0r+HYwUu2UdU2KwSMgDHR2JAadj
# DATA 2O0DDDTiZCeHSkDtDU7pDtiINuSEJL/9FMenWV97Nffi11XMq/wo3+fxkjYbwn37sL8nOZy/sTnn05Gdj2g8O2x1YwWx6ZfDMaFa
# DATA +gJd11XbM1NZecxlbj7r1rd9xYa6uR02kh3Nrx14pdjeK2GSegB8xg+i7JJl4Qh7FNw7wuBYGcosjpoq5Ya7H69fv3V798mjXfRr
# DATA odRWHAbRKI476mVt7CGbHuevev1ncDxRzZMg8xhTXkT1++kwJXMQSsCojxc3t2eD0WEtvcakP8tcHkoUucdcjKfpKm+hqwfA6iRn
# DATA lIXMcyqm3dqcMvQQCliu46/FXEbXmaDOmsxfdxIx3ahXKrDpmXoM1ncWvZhPKcmPjumoh4cqjUZfXyrwOgzjRXkIHGpTP/r5TqS4
# DATA IDvRb0paca9SC7VEmoNFG8CryzJcXXQ8N3rOqUnrqGlvrakbeqwRlNLCiGjp+6V1h7Yy8bqsO0o8WSY8slgoc6wnp2gmKA18Dj/Q
# DATA N6FlvglVfa0DmaMxzLDT1lBL7t4B4dGt1VUhP+h4ZDvZzWTtv//kf7kFfoB03zQ2xcidzqQq4UDSuQGd8+IsL3gXEcGY6D78x7vb
# DATA Ww8Qfrn0qkIE53I3DvPUEBlM20BSJcqXoLchL72GMHMJAoDNK2kYkD1VFS0Oh1LNZuWxo2sLhlj+i/6fnxrj64//fP/G6up1N/5z
# DATA bW3txo0/xH/+fuM/t18Ok9FQCdNTBDHq5cmzWWfSS9BecSd5nudjjHKCA6Z4CKIIoF/KqfWBeqEOJBSPRoLiDY/TSokQTn5CSAQm
# DATA LlMdxeFI/+iPOenc20eGHg/yV/bHbNofmF/Tjon1tDleTBxpfjIGUrG0tAcuholO8wd6YoJ7w9lKl3a2t/e0pp7AQk25ZUSOM3Ac
# DATA 2dKDjQ/Xnzzca29/srWx0+Yv05XReGo/SpeebG16NRZIlHr8b1kDDY38lC3d397a29l+2H68sw3geW5ts6OXKzLDW6Pn1whLNBlB
# DATA j3c39zYuW0tBAvuj9U/b8Hn7g8/2NnbBm9FGuJiX8FzJvjj29t7Gpzgxabr/ZNifHiw9EGKY1dbjnmU1FC7G0jrcJVvDfPpyNHkO
# DATA jL3Brjw9gLKf6Ala+gA9qlonSgjpo+WZyy3tc2K8gyVgdi1104Ocbksbr/LuLvgLtsxh4oOUVK34CvZKEV0NgbpEvpDYTWAxLSWs
# DATA LO1vEoDrwdInHWBSH5xGOqbmQq/Fxoebn8Ls7NuZ2IKZwCDFg6eQZXUAWSX0I8UFD2Epng6lNEvYBj2aRFMCtn7RSoUx7BqIGG6i
# DATA JIy+ctA0yYnATeRE3yGP5lAtOPVcRbczBl/PNsmm9LAiTya1jv+VeZq0NM8L7kSBGJdMQ0sa/XHbKYmpoPrdqbTP2NALuIH2Xw1y
# DATA RHRZTRBaG1/0izauT7dTTN3HM8w1iTcN/1YjsezWEy7W5dDYzcdQj5q/YT6VLjmpY6ak1O/QVmaSy6klBaOfqkQNpjhGkBc164eT
# DATA fk9dGOsJxori09aqCUUnmEg9FfibZWP4Gi1KeIkETwZTaZb8ODm7fv3cMe3ym3vJ7ZvaZghXhto408rvPqXPNKLxGP5z+9atG7fs
# DATA nZVqqZoxrXMGdoSlXQszDxc6snb9W7on1T5fjSZ4fdXXboHT1yGl5j2E3ujKFunPAyQr/In2zOyc9Afomdwf38agyrSZkheCxc7s
# DATA j1PXznmUntGH50kB+zU5w+Ln4EYOoa4sxpNreSuppf3+ESoAzlAbANcr0iXISFExKrGkeoCUhSoxTaBMzi91fnDj5wSrajdTbHkx
# DATA MMMWMeu8yDwSnRKuA0yQcGKm3XHSwyrPbPWm14gfYFuV/eZzc6RoJ/lg9OF8nSE/P0/OzpbAV0fVc0LQreoJjhOLtZlV3EmOBh11
# DATA 52Oicyc5P19KMC04Xz+gGvpMSQugyTwejfTVRN06RhNws1teW1VXVTD0n3K/76iv9BJeHYyu8mP1tDs1eNI0Ob3JaKyen9FeAd20
# DATA mJGz5Myu/UlnDFesOp+o7Fz11lZsv/q3dszm7RlP+bnsQo7OK/3iOO/VdTrfrjbmU3gFiIOmkpN82kkGN9EbVBHeF7eX+90TdcbV
# DATA f17cpllSPR72lod5/9nx4WiyXMCkgEe6fNjpgU0Tn03UpOf6CQxHHSo1xWNyD7l+69ZFG3f0LsNJ3lGLiXkGxx3IdrM8HY2WD/vP
# DATA iM0sa/8TzCWt1gr6ohpQH5w4c0trZPfGEQXml+wO/XbO/lhgJ1x6pc6YlpzLzqv/AznDQDt2Qe9q1GTMHIAJLLH3tg7dDCBKUkWp
# DATA 20oI3dq4v7e5vUUxfOyf65BuWwk6MN0kCBrzEPx4FWft9Z/Bh0KdAJ1BrylQK7jlY9hSQAcRWRgc8ZRwkqIcV4AgpzgcpeTcgx5O
# DATA e2rDUUehfDxBtcNT8EQ97b2XYqLjaOJMp7NQSM/EvultgMRannXS8RhkW4cm2zbWCz0zcKgk+1KuUWT5GHTIaP60LTE8cdJXq91i
# DATA XgYvf+hNiF25vnStlXYyCU5c2jan5AaoBlWRbsObOMoKVrCNjTbVNmd1kqEb1s8NZ0Br9vlzA3Pf4BsAd6NBxRvs7edlcPL+p4ex
# DATA isyGTH5baNNDXRvPGLOewwliH1KpzV56sN9cu65XWUtyxIyJShtpzQh1lPcaWZaaxYGRRYRTBk7u8GhK8aME4YEf0Pzm8AD5nJbc
# DATA XRFX19SgDmHwPCZyKau2SN2KxIc+f98hsCRt2+oMSU7AJU9U3VSdPqOdYdHRNKR2lPZy9CYM2fVTgqmPdRzFc+b7INLglBkNqR7O
# DATA chf/e4T/TfkSI9rPwi8qynJGP2CjL/vD3uhlDWAk+G/jcb+OTKRnRq16SRE93cEIguDQ416N6r7ibYcjlKRAFwOYLAmf+KQ76Sii
# DATA XjTM7eRyKx9dsKrqFlrxy626OAlqkrZGyegleLqT9qkPjlx4HwYbqLoxkqeWvlIXit/1AR4UMCgrJ6XAqfCmJDWST7rY/KC3kF3a
# DATA WESACBN9Mn426eBZSiiFE48JHQjAUUwDINEhRyehaUE7NtFp4xoSvLlsN9ZcFErIJpOQo7kQcS8s2j4VKC9Ur1oLELygh27dJOFW
# DATA yJSyriw8XXTSMdKdDsWcxUpRzv0Wgg+cp3GyFl0o2aiapcu1yHMEf67dOqE+aCogobVZr8CetgAvavyIMVqpynVYXox28qMZYack
# DATA XF7fLnt1VE2OJh10ENZqysbJc1ANjsHy28KmyBUYIReO+q9aaQP34nIMYtxDPj3qWcRTqNtDPIXWaMykbzFvjU+v6SDNhFPCoFTY
# DATA MhZeHDHTBqfOCRwVFOjFyTzNd768UOiEvbaETkoLiLic3dJeFRF4D41Bl1Bq2mX9um/GqoegoUFNduPlcV/JoKl65iJkqAelObdp
# DATA 0IG/t35O2yZ4zYGBXhF0CY98DXSsBoJde6bGcAWvB0oSy9WvOeUxIv+PktXR6vXrVfPzZAihQMmTDz9JxHrpemXoITWkU8EKM6i6
# DATA LjIQly5E3fDJPzxt7LY3d3c2Pqrpr3RfcTTyYcmA/e/CMb7FOOmIf9U6YZSyKRTZThl6qoBilxLv+tNNHo/O9MIMGKv42nUvN29Z
# DATA HTUdBO36X7l3MfVN0e2A/hEnBIXBdH91+dug6bt1vqK41VNwJaC6skoKDDPOPcH8HbPhCc8OOSoVMULq6KI8WATiElSjpsrsBCrJ
# DATA x3tJyv3M/FxfNXWsCb0fGNBsrLPVxda8/GtIwrLAV+gjZic9DmRnqxVp5y1nX7QtDtXHVWcivkh+CqeDYecqT/9XMILSUcS94rwN
# DATA wXvyHa25zNHBxjyT35msBWwpuBQPNOZB8Ck6Gb3IHSSny3IoRgpvWmJwMVMFKz0DbxxhqFC/rn8thgqkoDxNvsXi/38c2AzU4UqG
# DATA V5j1VHeitl7TKor/L41J+++Qfd0D7nUB9h2fpHlMVXhtKRaHYG+O9vGpz/HvUzNPXabPjbvs/jEuBZugasAnO8tH68sfNporB+9l
# DATA mvHXLAOtfadZt7+y72Q+R/VXBXs5d47CyankuP5O0tQBGwONqoujB/SJRAj70ZUW0xa4cxMFAdsJejpSNdcPNJpEHbxm8Qvv9C8+
# DATA msN8MIJwrelIdWQ0PcZwL9RxyBAzRXNBhIuvZ2ohddVV3ASeRcivwziu1fYjjO1AzAyKX/uQIdYyO3CvSS2qTDodIS8cnqaGFan/
# DATA ZgLlF70b5MGdy3xxGMyLeBRuSu053N3jtAwHoINdvzLGa8btjMPsrLhMSOMLpJN50lVYfclUzZU+XOwQ9ESRN2xzLtDVKzglzaUL
# DATA 98ib46N0/0zN3PlFiRIbwc0dBC3dJcbOqOS84ELazbhQXjS93T1xKzLLLIEN8s5wNm6PMTkzIRhrB33n7MI77WXlpJ6joH1SIHUO
# DATA i9FgpqaXgHAaDfYuIJ3PtKhg2keaIXGP8KsmTPP0+FwgS3XVRsBk2AgldW0CsTdFTunwWGIAwwX8PKgIWEXs0patrTHwmDfPM6S8
# DATA 3RpNPwQPw0gIUQATxQB4yO8fbn23Bu0YXj+HQAdTwEKWmgXTz3MJB4UylgnItzODpwP0ZhO7mLKHplcsbKzGrExO1424oWNja2Fr
# DATA GE0nu0ThdU4lZm6+t/dplsWb9atwZKgHmzvunMYrIdwPr6JaII05NcF06QdIpWBka/IpC1eu12CWXXhdkfPKxYmtMB9XmFrvrCKY
# DATA N51VglXxOuQc2OCAR/hAPIsVNsA5qra3Hn7mZ6myv7c+gJxSDn2qODc+kHZVcqvJYUzXy4cXvsFTi5wF/jMc1bJq+bt0xcVRSKI7
# DATA f9HdEcHKXGxHeMROoPEbybtGviUObjt7K0DRbOHm78udaODYvR7wQuHVoocxFOq2PD1a/pYFWObN1T3uD3oT3jS8/yo5i2XJkoOE
# DATA 4hh3gT0HdDPWl0DvnQKPz4TaxxgPxb8dpDjgHfAQgbaCt9LtgxvJAPjU+ACXhQ06s7qnJlJdDE6dZS0i62oGozkq9qzhJjMNJhG/
# DATA kLNIX/FV+2gEMrK+mBfMvCNtTnIDI4C/ncXWJXzxQAkyPpI5aikYNLDEskDYVhcxKhjub80KTt4gt1tolKzFNhw4sMc3HJ8ph5ii
# DATA u/sK4bvlOlxy7faNb920cDTwWSDu+7QMOjfu9CcFposvYnDuwjmEQeHqGgNsiL4Z4bZkeDiqYoGdKDCfyMpLjliIh+BrXwnUDyDl
# DATA HMDFANLPYCjnbqJv8p8eHUKOoTYOvQ2OZC380zniEh5uill0ESJukV0hRuE7HqtHvCnQVE+ifw3+nrQhI6Hdr2gvN8+rmiVBf6CG
# DATA oXYiezwXyfIyfk0JZRkq6CWlnwFNubP98FCLTjSsZBzsSoublDmT7G3yJSFeOsYG2rToTYQt7mD/UIkEP4PN6rqgahUF1qJz2x5k
# DATA BkVv2uketxn3WIwI1bOw5peZ3x2qjmuvnOFw73C76CGfxY0t6T55Uh/sWxTN1frt6+ep3+3qbcfD1t94i/4OFpyUK13EZaBqV8jQ
# DATA n6o/uFXaEygSQTQwFMbIbtW1RnGchtKc0dk5JI5qcKgai2pPhn0THxmAWuil4g7ogNReU+rAKDlLKeZGma5ElEKHRtVlKiqdHCHW
# DATA S7GqQkYG606QTmrxDuoO1YDPY/V4TG4k7IJZ7DevI37gfurFph12iuOnQ/bdSZbz2dMhotM5tBQ2IlUDKjrE8Ab5BCCy826Sms1q
# DATA ysC4qARoBrJISl4aS3RiAZQCbjUtU9/+rabGlnU2BCJjoUUCIs5Yecif26rVK6JlVAj+qwuBIqPov+IAmfFs2J3OCKaie9yZFK30
# DATA zh/9+O69WpZ6tYGJZZoXY/AZxFZV9VCHVwpayTHZAUZWOTdVcJmqYTGG6cOhsJ3EP/XcjQNweMWS89wnXZRJ9YGzbN9kPN9/g1oM
# DATA wjSD3//e+b1o/dDh0QRkrg7kJYQB3YW0SqjU0M9MxRQfweC9/Kzwb5ql28TbKnzQLYm74E5jH0Dic4ZOqWvDoFjhl3hS+G9Luqnb
# DATA eKpa6lTx+zqTLwdgwTZnXAb2Uz+kDf3MNlOk/TVNCmdHL9s6mg1RpEzOd9NdegquWX4P/J6iRY5M9EgJ6O+LzRfIP5QMDiP4l+E3
# DATA g3boPsO/y3DdBRJOvVNHbFpaFL0ysawGx9WJC2LTSoMa9nKYRTEiujId99FhDt7exbe8uZouHCvOBxY7gB1IgyKVDnz6Htgi5ef4
# DATA Tn4GRXDd8dN9p0Yf6pTKt5LrFcpxM2Z9e3FqzOIVrukFrmCGsM7EeKodhj1W42HAkjDjoIHqZuLcxHASYg/gcIGkF1XIZrAZ46g4
# DATA GJTMnLfROXXidov6oZ5jJLLJKP9yArM2wVXSfBEXJrjM44nRIrqU+DrjPnmCNL864Xc6gViXXttWHhNuzal1SketFUGpUC72Ua7V
# DATA gn00oyAYI0yYxgHdGRmOSOphKg6DqOM42pAQhYDXn0UbAoByFvSNcOyHYmukNF4UcyPAY+jPS/TWeumudIaAGofRUYhvgZd13aGU
# DATA bSeP0bVAp3jKvQAZvbT7bvEAGV8K/uQWgoDNGhjYRHka3wlHYzHOyAXfc5PQXwvXDFg9W+E8S6pI1gTznDhjcFRzcnkcgMkaNUWp
# DATA 7nQhnZHC9BJV1pGCoKkM9M5ztrBeKQsqSob76CDKxhDL9YbNkmzIJIm2Ei8FwE4q4UYeIWj3ju3QiNDV0qVonbVYpWnl8UfuUSKY
# DATA udvd9JGBf/gsi0OE3aQTf0G683ubt9ItIJfY5MBEPkEX76KrZBKtaFkKexmfOpcyIXDHHbDVMtkAh4nhyNtennqRrLGF5jrC61CH
# DATA zJ+MXgBsjtH8ElaXeMBBuQ6flxARdXCK0RffMWFftlwFp2A22APoKzDeLHMULy5Qv+2r0dD0p3nppjBtwxajPrcSCZ/AWTe5mLQd
# DATA B+IQTomWhrzB1uY5CGZZpazFkYGcl4p9vdlpROwoMxwtU8B3KzoDba8vkHTTUIUVzpD2T/EW0gMNEWupxTv+rtRjweE6OvZO7EjM
# DATA POFhGrtOPL6GzEWbpGlo2/7X0hL/pxJPg3TuRfIovYA3wtzaQm8FJ/YvK/f3BQcaw5LMgFvBJMTQGr09G6xrLXD1YV+OmKdPmUNS
# DATA li2E++jt8fuea5TY5ZoV0Gyv4HeVm9yozmm8Gnux8OneoDMspXmaKNYFrVuAYC7pSBg/vaJQGweiIDcUNOkYVoyVDwRbNqZMRuM+
# DATA 6pYAHacBehPEeqvhTw0D2ejJ1GBgl1ZCTlAr1yVdLOOOhRBEfrrseAUug1dgA6CPU/L9aLjon9LpL+FOGB/VeS4d4PumPfjKPUoY
# DATA ysWHdeE/a/2xzVW7jLgIhGqhfqDhZ0zcpD8OXFBiapsy3xNbG8qYuh/gIwOxGVcgjB1M1mP4E7UMVEIk0m1QMF82b1pwFdRo2XZ2
# DATA xMty1h+fNyCmbSlMR+6QdCxeT26ufvu2HLLhzEepQTx6OjQoR49HBSMdYYS8aihZPqpGOnL7JQltiIfiT5iiarc9XBTtlAUkflIR
# DATA hVj7ThMDEX/MkApZ4sOo2KAQternScgAJhJh5ObNGxy+mLDCNLk66S53O6oKNVyvtmVV/KpDucEgp2jzi86k38HVqM0NoVTbhLvK
# DATA 83KeuP2p4llHqUGAwORVbN+ltLaVI1ErFXYfc/+27V6CU6TvS7zd9Uv/quWQj1StS8qh2ECbsrO1OhqGdIp5v0k7YZHNQaAQQCHm
# DATA HSenh62WtxxOMjDZrHsI/UlwlOn9qIcQni/JnbEjTkVhEGXRgOhmxRT3qRI8QmH2hIqeRhgsOL2cdCbAR8ETmegHcnvkC2aPNWFn
# DATA +WqI4lhNcpditw9zA0WdXkCIPVLiAjRJvLHKUET9UdtQBzYO+wH5Agbn+whQOeKFiBQn3E9wVrkn8D4TOWHhs6jg6osoADmX+MJJ
# DATA mSHuOB+MHUOl4+pgNea691y+7OJSo/euhSSK4Ph0+BVAOAIxgMLBLrtaDYKoOoPqaxpctIILwCQ6tWWxg8NLVTLNC962qLMLrHG0
# DATA TeHF4kijpULe0tK/9ZAvpZA6GHVNSDgjUB51h9MBGW7Vyza7Gur24VkauuSYoiZLUuh0aMqw5+H9nY31Pe1ouPPgk515ToigJr+t
# DATA 1eSus7vnNGjb/317DLrumxd1HYQpA2xzPXPSzwzXqXGEKyj9Kuk5zFd741Nb/BQchOLR7hBADzYoZ9riSpw2ud1rF/vC9RDRT6Om
# DATA v0vE55VDfHAUiT44Imq2aGJLfQjkMUTGu6LUtVQU63FlZOY1+FDKXeqqYcIeaMoUxacgm1rMvtKibI0RgMQLedloH88q95pL222W
# DATA KvTbQpsjtWvGfLQUvPKvrxdxgbqAypXNZlsj6VAWqllDMeOOdcl/3lfENvSic9BW2vXqyzvc+v01zsJJKztPvo/OHQ2ytx8MbRSq
# DATA lc0QYKdS3w6yqB0bP67bRDWLGwj9zdrzDegyFYXvbVCtG7FuvzH+NG/zVG+gij1SNZGVe+EtJ7F8IssnM9KLMtbv78qS+XbD5gob
# DATA lhFS6oURmC5HnrknqF4qi94b1lJCo+5OB0iZ+4VGoVpWAh0qF+fjVAvhTICepellDqrUe4HTawN0m8/z06ImOWSMY5QGD0aG2VHN
# DATA D5fVvQoSPrmN20AY1YPaPF1d3etQNE+TzeMyOUE12lIk/RJjBpbkvpFZxRqIsq5v9DX81djY2t7Y2qsn5tfexqPHe5+ZBxufbu7u
# DATA VSU0KieVdAA8yxstoCL3FAlrnCcIBcukbNAJvVwKysBrgP6lo0clC68btAPS0RMDsCdfwlZXoAuo+QI5O4jBR+nfASaptABQ8SAU
# DATA H4VZ75WUaecAk5BkSnPpp1XFWikVrM326iWCNf6dL/qjWdGOuJtHLzkyKh2VqvFSZnJQoXdmoELtomCgu2y8zFAkTE78pXa/wLqd
# DATA V9ZZBte5pA3r3YKApIl2K6FvnNpB0RTIap4fjYu2DcnFDGbqktZgIgyng9NdjtHtrsxbwjwCgUPrRHBLrifRUAygUAeBBQGrceO6
# DATA y4HMFtixAvtghKE5ZxSDirX6aEIyXskCBYX90/56lK/HmgcDRBE/MtvZQ76+wK8tDqTiVOFHQEfmHjdVuw3z0G67p6rkY2eVBL73
# DATA GZtJm8Z8VxTHdH6aepcJG3szkeBn7nlrusNQr+1RaYozch50klR0Rhl3Gd4ZlsyHepNfVoQg3FTpmBsJ5A5Yrrfmgt0Gd3X3Gmu0
# DATA 4gj82MAIoxjcEG+5yoSNC0sn1ZZXEYYvu+hLsHLSNOVhRF6SRvlRGeCqr65Ww99HSlI+wErhcd6CRyjdojuu5FOJleTkhcMUcJdK
# DATA DofvvURjBB3rZEdDMYYGjfuOx684CEIVaP1Fysext0znHfUg4H+6zF6p9B3wmLQu3J7ND1QqYVxFfyoaMThOBxXdXuZGK4sgYVke
# DATA kydPmDRutfJjdRfzP4XEbvHC/SEqsYMPqhoIFDJlA3UikHSqNyoby/eGmdk0enHLLEF4DUfuT1m3iVDvX7+OKcA5F7eQAMrCexyo
# DATA IpAhm+V5y9Idlma8PCKRLsttJWHFSTKWwX74pZCFXIkgQAlhF34rUodD8vvi7WkZOe/Ex3k9MfnMKeRsgcbg6uOeLj50rnd+uLxY
# DATA iHxE3T44fsH0XaWObJ72ZL4G5Z1oUSI6DL3zG44sXSJCh57Y2Vu6g7lzx5hL+6sHXrpAx0sZISaxJeRJq6ZCqwCObxndTngKF9yx
# DATA Hhm1uB2VN6M4Mqtv8wH08KP+Kwg9UD1epkUVUBsvRgDxD2q5FbRVThQbL5JOdzIqLIL2xOKGB/fZr+GOqZu98A340n2D+RCWLsdY
# DATA tqi1y7FuebgZUFEZOLK0AzHsUdwCFNlJJAnEnSn3KXAdhE0Twl6LbWDmjRqH+EgXt0YDiKa0lyFz6FCbIvmTdx7MnbWUCaCJfc7x
# DATA iJPAC6kdfAJpEs0LalUZrG1u9f5IxNUegxwcOsT6skoy1lyEsmqvx0un45OVVdvxxCxBQYnDW46G6t1wXWfcejyYpAKTLFreOkxe
# DATA 7LaLz7M5Ww4FXG+jCfTvUjqv3S8WJNzvbhOXan7twfRXoXIQ89HLyuam3C9/Ac1vyfmnW827Pvjz1G4lGgESw4M97QHIYmgAFjHK
# DATA lIMsE+q68nmq2JsocpZdzLyNJbOKBHzCVLFA1mdO9PyNP/zvX/H/0EsLzvlXlPt5bv7ntdW199duefmfV6+/f+sP+Z+/jv/5SZn1
# DATA 72J6sfzMXVC1FNFszcedAhIxm5/Tk8EF8zbXk8ezSf4Y8C9K0jjnXSVOFdHUzafm8UxdLxRZvL++t/5w+6P24/W9j7WoZRXu1iSb
# DATA mrPRVqJXZzB6Rj6E4Cqm69A5i69zwmKZt/jR+tbmhxu7ezaxMTiq4iswoT5cp6e36RFGjulUx7dvhmmRIRmCqB3NrptbH5lv1Hv3
# DATA hf7w9s1I50ypBxuPcRq+tbS7p3rU3lp/hI6cDZPOhBju0h9vP9nZWn8YKbAscl9xYbzURKoit8Sdjfsbm4/3TAFb02Gn+3w25kq2
# DATA Hz5o7+49+QAwadK7V3oj3GS4ge7dhf8mg87wWetqPrx67y6md0QolHzauooQeeopBnnd4xiGuyv08+5YP4HLj/Vwvbsyvnd3BauH
# DATA CIXNBxtbe5sfbm7sUPhLd3Qy7oOkgNBGGtcIYY1uvn/+9Ptqa3y88Wmk7BFiYt++SWX2tr+7sVVa6sZ1KrXx6d7G1u7m9tYuglg0
# DATA oFcYsdItCsroSf8UL57hv9NXU36MgnHaeMXlX+aH6qj2j5SwlZ6r3d8ddIoi2VWTTRdme3c2eu1Ch0i1Qxg1H0JtLnxaNXQaKydN
# DATA b9IHTx4/3LwPG/GPd7e32t/d+Myx4cSB0lyQNO47zAQhMjajtj2hLyL8tMPTaeAGwkB1UfhFL3xrATy2tgBk0xkdJfITX2hg5A9y
# DATA 8XQn784w3IHWKeLJEczj5tb31h9uPsBZVHdbpKz4jZ4eJHEemqAX7G+zYGdO7gOI0WfMQfVr7VuorkmfPsWwJ3xR0bEnW7vrH260
# DATA 13d3N/aQBKeZg20sCb3MIAXXrzjEMVzaCXPyikY71MgEBvQY4Alu+UBBc7NAH8iE0HjQv435oKHKKKwRvIBJOKOQk0YjPadIt8lU
# DATA AE014iklvW7UvtNUrPbH48nwx53Zqx8PZ4MfK3qxv6a69ePBeIp/ZKrQ00bjWvYd7hXcthub4ZXsiHvhQkFnJgyvmB0d9V+p7fsS
# DATA rklao2GJUHaJFY1gRrZ7I7x1XHjfOcvKe+9ecv3WjQWOwIPtR+ubW7F8PIaYYY2NCeR7H+P6qNWiw97vDTvqpz77naLb76vfPFFl
# DATA EG4XOaG6e/KMSow0zulOw61KXs57Vm0JyZpur53rN7hLFKuTNpfy0DGYbChrSbdOedBIsyy76MRHaTSoagNcWscH6x0AnutNDndg
# DATA U1ND7bRjJ1lu2b6mkH67rf9HB0CH6XimhKWpIpvwAuy+UxJ/4Vn/UE1lgRoLULe/urm6Oodl4wTtfvbo4ebWd10P0Tg+eTWW+JzG
# DATA 5KKsb91X4vX2jttobVSQIyWoPBAzjywv5U1GHfUqkderENUXma1PdjbRL6tkCHbeWmLehP9ogVGHbz+b2Jmt7b22+nDjvurHZxfu
# DATA CHpLXB7afeEeqvqePFzfwetOKTp7m+xOAgGbKYikNFYRHRxlc5A55vKaPNAHWZD61Z7cuBK4fdJ5nlsEfAvYj0hit26VnxYkVLb6
# DATA gFph7TgoUacdWWxq3K7QAMUmQVNWm8ZqMbzpt+fgNyl1UML5EsY/N79n6ImkzqpdMjy2nB0V/oNMoX3Ua1GLVE+4kjw+H5G/fAMI
# DATA Bx9KcdvyIPY1eRyBp5u1/BFRDF5/sLm1rg4OvIzZBNsCyR+bywSmvpI48s5JBDfWhMhRiQWR9TV0qzhy9pEb/2afz8PM908jaiUe
# DATA bj7a3AtR8rm3ZTj5naNpPpk7uhiaPrpX2z73h6O6NwT5+wRCHdpDgpatYavmK/OLPjI/zTcVIgGO//7H61sfbTwIAfpLYjidM9X0
# DATA NrHJw+uYxTULu2JYWNMNEHSttMKUGN/Q+MvQeN+ivVSZf4Jpj968oRQdu1tAzjgUvvbXmh7OpMbct23AtQUrNwc+FhdaGgHp3Nfl
# DATA KLClmMBVGX+q1QOX5P9l0PAXEQFoiW3nLhwOGtCcSM7pd0LvK7KWiHaz+ZEsJfT5YjbLudsjtEzKI+zOt3jjHAdiUnTOAteQKNvi
# DATA NQHdkNYk12JKqXHnFMoAtyLALaGoduJAAw10ddqXRW6jRNm4zkebu7ubWx+Fd1Knuwx71dL99hVkFn/j6YRwu10sFJOVWDcLuir4
# DATA HbA4bEiCHugEvqwd4AIulDcl78MXCHjCT4H/zeFy+v7qzMkD9a/E1lbFJ50BphiFNvYFxK9BAGc0HUDUQAstmFXIVbTG3/O5TPMX
# DATA nUGaVQBv2moah6PeaR2ruj/C1wTFialAvGINNzWI4rbvYOjA33gsPIo2dN9v28uzOJ7U4EMC+aTP3kFfJp2XmOX+1dRobKR6Nq5k
# DATA 3T0dTjuvorpVxYfVNF5czRrpY0Sfg+qczsuM8QacI7zo2ZSCFwtdpOqGiksUaqSPxkwfeCryKQtXV8C2UHSP85OO9v8uSGWJuwkK
# DATA 7ev3B36GGfetd7AWmiktQo1eFqxk3+c+HJSMBIoK+FlHJQ3vUCPtWNgu2aWImUPVj3dE1YwLyhL20Zts9YTnut/DGC0wQ5GfvgkR
# DATA QLQ9CETF+Q+4VtjGPlR24KpJrclKqgZ1WSxmflm9Xqw9rWT02gTTi5f1g582SHlqcH31c9jsJ51X/ZPZSRlQv0Tl9wD5ecK5JmNs
# DATA 0hWC9q1mpnNNyTaAXujO6o3bq9lBll2C2Mj4Xcbyw9mjZaqCSeYAb7MJ4PUNvU8p3FhvVGv3vUgP8QMnvnjQQ8Q22G5u2DHJKyIC
# DATA ifBqojFIZBVyYfv0CNXDRlfJX9AUxN8NdaM8PjF8bsxulPTpq9VVVMvqfvAu4Z8+8c7mILJcfII0Nt/ZGWmlz8+d7mjBHkcpLDVo
# DATA ds0Wlemp6rYiPPc3Pt5++GBjpw3gmhuf7nk9oZmDCJOaN6+uKjNFDH3qhTbK0FaESb25ejP+Kko9ztLO4Wg2NZZk/LUiGjhv9DEB
# DATA SI6GfN6mC+nndjb+3RN1uXygJNWPNnat+OjgrxS8O72wfPCEG4IXI+iAUF42YZtm+7pP9H1k6BkLcdtqZR3pwG2dcJNupAuNBsRt
# DATA tW4PH26C6Ss0PxsKekAEodS84cn6Oo/emSJhTUPVNFEjH8AK/pCdSy7k3SZI0FPn+cCqw9CfkZgRWt0CCz5MWFMfASutiyNSR2cL
# DATA jWlI1dSTH85GU/bnzQxpCA6NjcLOBbZeBV1iV0tJYjWV4owbvFeMDXA+2XDd4tmMpeeK+PPspKrC6u8vIcftbGwBXZBiXGzv0PKh
# DATA 95GZdzUXaommWmFLj0H+Y6sqL7OUqbxtYrDTuSZNOFyZJmJ0+e7W9idbRFm1ZOV2Xuy3Yl9Xf2C2njH4nQ67UhEmdF2tiK5rMR1F
# DATA tfqK9tlF9GFRvXNUc4GKJBhSTOEQjQmuUtrIcFwS2QOlzQW02Z/syME6YS0bn95/+JWruVn1A+EwJcpuVv7SsPFC4r86GsyKYyHP
# DATA mPkO9MY8hXR+e46DAe/QmggWYA+DfFgoDtJGo36LAfuBCrUBFoYzbRW52gUdtUxFq5bWgSg300wnhMmCWyf3Q31w0u/ydMjOlKwc
# DATA nJjRpIM5pHHXCjdE4WiHU7UM0Kngy9iA/9xUxP8457xCvIVMbXV/RiLq2wrN2+LHb46akNdOsxjRvzDdajxcPfY1H21xyotJt+2c
# DATA XXWQimm75DhbatSQr4JzywST2iwx9HEwvilndgK/iCr/nQl/d/Y3A3RXaXcTHePZi6st1UmDu5/J4skxnzQKCpcMMgnD4/JMwsZ2
# DATA Mcm76t4nMNKnoynq1ChIEwA1Ob0WN6RuciJ/Fr9vuregCQSWj5FMcoHGeDSuZd6G12XdsCSHjTg2ljmcKlhBqr/0wJTyLPruK+Va
# DATA nHmZGtVZm0VnINOu+OUn2+CRhUOPZnReLO+zl/+ZN4ZJ/+w5O4PyCZf4XhL6MjdLfZviAtnezkZozvTPFGCh47CTFRoJLlB8CGRj
# DATA olKUGj2aFToeNpUruan/ItdsQP9uT0c1xoOEsC6192pZ2QRWO7rgYr6N/0+Z1SYOPmIHhitqkk6kNjS3bkadlX+vj7L+nqUk3AVg
# DATA Yo5/WQ59soDNqcQgKABjPVf7ZaJfzUrnuktuQksd32s5XSkt3es/ywug1Bx/0SiOO9dv3a6V1/9VOENEYWfewkEi9r8LOE2UrO07
# DATA dKS44i4P+i3oB/3hCI+g48cgv1A/s+Zc38xF3BLKz6FNWun2vPIzYrjm4/l9PORQe+kQcqLuqJCE/nbd1pTNd0Xl9cEamwtlen2b
# DATA CbJHpzEbg1tVDRue/5Gd2WXS8y7wHSmpzAStfcWLv5j7TUlHv3bvm3c5+oD9IM6c5TzhcHgPqKsV/VWTAbzRq32p2HQBRwWWkD2S
# DATA bS5xWkXG4lGWyf4ZHQuixbhKFuMvLcEpHS/qGPCHJ6475kbpbxdGu2Wucgjzjqhecd/ors/djb0z/a5d0pL5vD8kTSprolCZiqoo
# DATA a2eD1+puE9rbLmf7tI+xcXzow5Uh/kAsZbk3xH3b8UUsfP4nQXiJ0RBiQZ6IA5w191HEmEMFWCFr5z4YgrFvOR9E7FylbeBqeOP9
# DATA eOPTcKBYbqEQBPJN37PqSqt5ZvmoP0ycDoeGsZhRLGJjx+oqO48lLmSIlD1fwNEQGI4iD0oqHoxOAbYspjW0b9VdxsRpOhIwZoiZ
# DATA YNhlZAMvv1jTCZxcRZLUX1IVgV/SBpIfL4YhjIvw3HlzSJCH9eGWpb8vahGEoaZBaMXjfIIAiuz/UQKSHGc7HzzZ/Sz083Bu9VK2
# DATA lYhCVUJ1REcXmyGpjRhO0wiYJEU9nxQvupNp8JYeY0CuklmczBT86qHaGR88hHQea4to6AKIKudqsUgSDDUv4vfWB8FiVSNZX2SR
# DATA Lp9po636gtDTtUF+BPF2/WfHU5fRFqdFAyixojUnTqoexWBnr9IsngSaAKr6h6wFpoD6xv0HDx9ynoJZkbcxsF5A6RzNhoz+YbYU
# DATA V0GYj2qDdKbX1bbCoCrdSfNVZVZqp4FGZ/IMe4TJ7qlv3TbCOJpf4LDRHosHc17P1PsDtxXAhIEY75ZTSagfhbnH+yH80da6Xv2W
# DATA 1gRe41/tiBJVt1hzKkDBmFX68IIyGNadatxS+EYXu06prktzDDPYdU+MT60aLao1zmEBCCI1iOu7n+0auHWkaebX9uOt7b3dJ48f
# DATA n1esIR0MPjy1LrqoguZP8VHzxJpQED6fnBpBwVJM1eGAmXK01/q93YmauZjynlpYvIlphuP+FBugXlnf29zeIl3Lrshfu/Ahi5yR
# DATA uYer9PTMPUHR0azvbT/avN/WBmDFb9tPtta/t775EFzApR/P13LcFj1ywbGjZSfFDP4ZHD25YaCY+N0uMRyZo+hVKY8ZO/LyOQsr
# DATA dUvLvcafrPmwqDZ4suo4hqs69xgZgKdSBo22LBQqY8dsKWSxl9tPZN7imZNGAe80sj3pinZlbvjr1NYmbu8TQzIItQOR8oR46Ro+
# DATA jdsJEQoR3h+FIiRTg61M93IlSam1IoW/jVAK1zmH3uj2WqIS9H+k5yD2+5UXbFjQpa3HB79fMFj4g/X7333yGAFPq4KfKftMIKzH
# DATA VQAjAF8ES50id+Athg5T4tvAEh1VDUw6L/U1u+SO4NwOLCKM5+pRdfMPkflFrl+bLsPA9VuHpW6uJC1nA3Um3WOwCzTL9A9cQPVV
# DATA YspUaCTegU7BdtCoEOqMTfd16xIYLydQKfCl3nYUawh3XBkiRjUYg3ut5UPsOErty4t6qI7QE4JTdhDkiq1FtQNcer56gAtm2eIa
# DATA AjqxqZRk7M6yp8C5JFPogb8NZeGSwxEtnUUSWZgN69EC8PSXpxvJXedlSD5RbLFKHp6YeVIXky9XqRo2IfiDp8Kz8QgxzQWFRE7A
# DATA rSZ3DrvgIvVkOnqeKxFyNOjVk2H+knEV68yiJEaEXocYaVuyWQdKuk7Rx6JpR8wTLMIiEffyFzCn4hv35UK3Uppj1Id9tru38UjI
# DATA gHp7OE2ozVITOFngAoRTJNwavABvrgYjzVdX3WicspUUapz4ljZBJtGSLg02WmtDRJvJmqajzUp6Vg+EL0nMmhFKpilxE7dM+Dnt
# DATA /WbyNkdJZjchmUjzJ73PyFnG4aHpy5cvKewMNqEiW/GdCgXUi4vFHjND9OYX94X6m48Qy0ucqwXEBrnbIXfEoMfTpuSp/KX6Gw6c
# DATA M4VQZvcdzKBXq14UPtspHW54gH+cy7gps5uQN2vXWw9j71pyfd4Mmi+ktV376zkrJwHvyCEzCiFEMtFRf9gvjsvomaMH5RuE8HLN
# DATA D2Hz+9IX7hyZUfFZUMRxDsQSMcogMkYtQlGCpqPaR5eiIt+m3c+jyZykB/RKdwTVJKqGSBgwJ++jcnU9Nb7+cbEOtCB520vxBmeo
# DATA onGj2uMq6jTrWSRamW5ELqOREYe8yHW7/4IEg0URzTEzbytRNT9QJ2SIvnKle1aqJLl4aP7TLy5tAeQK6iXH8e3FbiJnLh1jqsUE
# DATA qy7ok5HELTl5dzL5AmY77KwnpCLiY2jFoqJZXHYXgz3QyPRyF8Qk9/ASHZOmFxTo4xhyvoQPq3BQT8wPWoSIyB+dLVi8BQR6LFZ6
# DATA iaBFXvgWwcVNq9FYKQ9azVJJidOZ6nHrOi9y49jbWd/aXb+/ZyOMNPB5zCBuLzUolZbentyrA1dEqs9F+Ia7MZcuIoxGPhVsx4qI
# DATA lrPM5Xr5q7ESZTGqUeyDIP+0s+iMzU4XTzg3upK3XJf2IuqReReR7myCOqzWW8lQbCd6obkTtOnwvTr/tsufacMkZHuC8safBJMm
# DATA xKczuIbq7pv7pD3vNrXNADeLnXd8gzPT0h2Yq/aneXVFXUoGKYjOUpUgUqVLkrvDEQMuoCLgunpm7o1kYxSspcRJ6IEn/WcYwOUe
# DATA LffTJdcoHo6LasmqN/0Fb/v2jD3LHTlOLy/MOiWz4omI2kHMjYhHKm9D8T5eop9WbHRbqSf+AfBF6fgxgfuGN0r+wNvV5WO32zJy
# DATA vcau2kYjMi7KtxFhVPTUB4IrFUcDUz21b+p0N+4FOikoUD08DxW0qB49MjhmnHe53eZMvFiiCg3PRYYSGYAkgdjBxbgK22bub39v
# DATA Y+czCAP/8OHm/b00q6JbZrjzj1c4rHAlw8UhW2cJyTKn3fQJMx3xx3OpZeWAv07eyAWuGIbjpvQt52IL4ZxGeNP8dHw6CszKEpVH
# DATA lLURtjSrP7NS4Uca63B+/ZZ0D/i6Ji2E/lLwpe+M7yCsNNLsM7Z3rX4nSZ/lw3yCW1J9qM+Jp/cxnopNI7AZ38U5wsi5viWrS/K0
# DATA 3xlQhLQ+rY4bDj8sj0MzLhnxqK+LxCYbncNFwpN1B99RrJejptExFhcP7yLzh2EQHOYPLlexwK2j/gSDTIaQiIlL+P4S2s6PRcvT
# DATA /nqL4n9pERElKAZcG8Omq72vAwcZL3SLmls0dCsWPvKWgMshVO49sgk6kSVXyN1WZ8nIFhxooM1zFhykJzG/QWAU67cMWayoKhYS
# DATA tliPHENzWcecsaNST/8KlHGmt/UQHC972xHEwoUXiQOo8jEEILV88iLmy+tC8Gmdgc9UXdviUslksJIyCysUIbrMDODNDDLBp6Zz
# DATA oGMjGRUMCBw/LwL7iHFErCHvjh34DIefGc4lWQZnPWVMDXGD8vE1WulEEc3RCcaHYMy5BgcQFzVpgqxE4oDocVA4clWGNh2ORoOI
# DATA K7zuhFWLmUfkBUBdMzfuaECAQQpZWB8FED4buwZYzq6Z47DjGNzs2bCqnIiLOV/GbOlFVdc2/DvQXqtZiSmunRB0mm4b58K1wW9f
# DATA MjCFqqQKSZii5xNLyat8q9wzKrANEUYi9FiIcs5NZEnYq/1WSRYpc//XAVAvclb/LGKsMp3S3/mXFTHJUeq9AMkghI2AYpi7VzSc
# DATA S5IL0zs3YMalCaKQeH4gyYQows8Ozv1YD7mhLr2BFttEF1I7RvhA7JoRGUVchVouNi/eedLWRfYvSVk0RfAWlMNnTgNloW/7B65L
# DATA W32xr0ykX4XwUPc/N2+c8L/SDlRuldg9H54x8pIzGZeZ6gqgJ0LbHvW75Ebc76kP+0f9fIKmHPGTEaB092vzN4nF2wTJFJ6I6lqt
# DATA kI9nVpFZ5AOt168tyO89ekP8n5P+NWiINR4pQZIZltkSLBO/0m+cm7vuURQO68KQWBIw0sHF0u0IXCwb2/88BwnCx/UJ7P8RDlvp
# DATA BeDLsL6bECuJvHQUFwWOnHYm6oqD8d7QzZUkgMdgzkUFGz5GiQQvwhKmYd+v1YJi3bzp9pcBOiyS3BmP7ZrE+GEIQUVWKWX3s7wx
# DATA eTYYHdbSa2mWndcBi6816Jwc9jpYrOlnEqvrLCEUKRDTxPoIKcOc1V6hs06FM5QTv9o0m9RGsja15BoPe+aIxqYG+vOIXBn0pqNs
# DATA m78PzstaZ3cs6XnhEErHqcfMUIlnzyKquahnj2OGMFqaKxEPkEVDy6Wu+6JujG3HPikeBdkEpfTEVK+XCikxyluQwKV8z4kKWxG/
# DATA ujLhq2zzObJVZExWqtIzJYUqjW6Iqb/DqxgVrBvFYdu2Vnr7ioKlh1+XexlEii98b/poY2tjZ12Yi7/Sq9NlbxfWii96RKUyL26C
# DATA i4qoENmoBn1e0D9CV4ZBOBeKnkgXvdiAZ1HpPTJzroxV5eL+T1WAPcZPoP14Y+uBi3drrRklMvBFFDeh4SKyYXF8C/pEcE0LjdPu
# DATA 7wgpZHM0iTnlFveYIyLNi+cX4ozXFNYGQeDb+hl4y1KLemBvZetmetRre+sS9dTnazE1Pt8Lx8YjySb8RXJfy9XSY/YvB16Pnfbm
# DATA SpM2GmtRFsabxtoZ614fjG++c+ir+Rp9/5ZKAVch4E2jc7HwJq3ELRnrdLicHbJUGSAYdMDaUP+nRNgXbh5LJS9O0BGK8qw31ifP
# DATA ZjDZj/FNTQA9t9JNYuDJ4WzYU2w8UeSvM0iAyGp2USBhHM2mCc4b6LUgJwL0uWiYhLpQM2CMtzvcWC1dXpa4a6CXbD02aoKyL0ja
# DATA rCwjcFbUJHTUzBglauV3NHvLE3LqXKw/LAEBe+nShJEwMVUbp7o1mKNLfMbbZuEOavK8LDaR5sMIsMbf4T/wZYEbJoumqYbXDeh4
# DATA cP7pAIdXfnSlwM+444FTDr50sjhac796E2MvfhkthurfrAKvtLvxsCla1s6rGssPZ6ozRSJ2JxLF6FTWzd43WwF64e3TYJ4ckdOd
# DATA gLozW/XSSeA3UVVpaMWfP892zhabL39y+PuOncJeMhuquxnMJGwZqHpWKKpaMieORSQ6J9o0gj+saUJugapZGU/66kgI4GVqehHk
# DATA 5SxgHavzzFgRXJCgA2cplmCmgn/DpT/sj5KL4Z7bApyBYqqu85OgQ2uK5JvjahLOgKrNJlkRkP3mpB4sxa2oThUA5A8XV0QfardR
# DATA kdVuw2q02+yFAF1T8u20hjxHTdg3Lv4/4Cq4/lp32BiffuMd/29V/e/2zZv4r/qf8+/1tbUbN2+8r5/R87W199+/9Y1k9Rtfw/9m
# DATA gB2hmv/Gv87/+bnXzq6Seupqc61+FUWNq839s6v93tXmVRTspoo+qKNytX4Vs1Sox6//9s1P3vzF6y/e/NnrX77+1Zs/e/PTNz95
# DATA /fPk9RfJ69+pv3775k/VM/Xk9Zfw1+vPX/9WfSwEHqji/1Sv/+n136vCPyn5qp6of/9CtfCbN3+tirz+NbxSjaqiqspfQWvq/36l
# DATA nv76zc9UN36q/v0b9SHVqIr/9s1fqZe/eP1FQzWPKqyrzbOrOoeK6sTdK70RwkBg0ot7T58O78IfyUBJWK2nT6/mQ/Wfe3eP807v
# DATA 3t2TfNrBDEVFPoWXqD3D9/gGDi08ftHPXwIskvpTa9Dg8ct+b3rc6impspsv44+6tgQsF0rYy1trtq7j6XS8DPT9BXx6n2pZ3oW8
# DATA Zf3p6fLj0aDfPfUaYCFsuZh0k6dpkQ+OnqZ3Eppy/+H0dJB7z/onz5wn6CrXvJOMDn+glp9fDRXTgsKHnSJfVn0RjwCUZZnELPs0
# DATA nB2xCbz+rycv+sUMpd5pfjgaPU8wXY2Scp8dw53kWDGS49GgVyArnB4rybij2GJSnIDgTJcJSKicgLZbPVds6STJOwWYJ6YjYIqN
# DATA ZHc6653it6NJrz8E2CVGklUCHYjUJwAIib3GrX7vMai2Qbw5Au+R5MfJv5v182nyYjRQot/dFSp0F/11JvkAhtHv0shUd4/g90qn
# DATA UPulWIHnjeLFM3iHMiWUPVHVr6iH7706GWCrsiZcpeI4z6ex+mAJGt2iuOBnaOfTn9FSAIR+UOQHUAIE+3xy7+4KFVR/4EmAYwLp
# DATA /nCLoBIIPpekAmtXh2WgqsQ+Pe+PZW++CewLCu2qF7A6vA/urnTotEGr4vtDuFg4w7GmPajGXRVVx7DzQsko/c7yoHNI0/II5Cb1
# DATA uP+sw5sPWiipb/tFPoFzjHWJUoXaP/28MOV2xx04wAk/94vDFjRld2A/vhxNnuPaYNEV1R+eVBgwiYY9+FTPz11OzWSnYgy2HviC
# DATA KNPavb3jjlrCMcjEJqBNbXH1t5LVhg1V/dq9u2NVLE/gW3U8TpPjzgv1x+gFaHch898xHgBI5YivYTVQzISdOmok6lt1bUZ3OCWJ
# DATA q9M2hSN2OprB0sHHWlGlj65qdXzvbq//wvabSEPh74zD2XTqHRh3KT5QQqZu5jBX917A2+WJ9moB8+Bo2FOn2qlvkUVbUX2FfU6z
# DATA HZl2fkCTfv3e9iQZ91XHZmM1SYq0HM3UpIxGA5ju6zDd9zuD7gzNkUeDEUr/eYf8uxOk9klv0nkJFAf8+mCG1XqZzZH0RjktZS+f
# DATA AlqhukEo2XUGZ0t1HOy+CFyDQEbdkRLR+6AEp1m/yP4z412BDXfv7pES5WEnjt0TpXaXnArQ+tItAeq1uaNUfargPb32TldsIjL4
# DATA Zh0p+x91TsZ3QF5/0emeQoeS//efkgv1n1ZN93oFiBKcJ+bliunbZv/A7f/A7edxe9qWl2Dy75jHX47Fz+fw/wMx+HfM3xdi7xfj
# DATA 7l8Lc6cdKYdvGPq/nBOEBH8+71SUflTkmoOua7ZJ6jzVInJ3zT/lkEGu6dhhjo44AFKNXW0rVKvwEvEUdPsTZL6owPMmAqcHRRrN
# DATA ggtUpw3yzgSh/E8U01Y7a1BHBqwG0T/Je8nhrD+YwgiAPhY0ZNXTJwV8gtKW7p8eAbRgOXpXywOFLxCQODAaDk4byeZUy3BdyPMN
# DATA HB8mTrEt1DRbs7YWBTo94DCoXsQuwqIso1gAZ70oEMco2c3z58kP1V4BZy1tXDjOB2PUVUEnk87REawSCCSdo3x6akb42Wg2sTya
# DATA h6YknSKZzIZG1DwEZ6d80kg2ONEQTCmMYzYGaQXkTL0LYY8XKMOoApBCYQRCkiIPBZTpDE6n/S5KN2ps+WQKNv5naggd8L/Qrm1Q
# DATA V/c47z5HlSeadlDt6XTmv//kfyt4rKDlRb+gojsaq3pQnhRr1kjuw/onaJdHxAs1sFMYOdcFX0BXX0AT+f/H3rs2OXKc+b1fpRxa
# DATA LbtFAIMq3Ls5Iw9vEr0kRXMoMRyiXhSAQqM0AAqsArqnNTsRuuyu7NDGkcMn4myEI2yHI855T2lFm6YkKsL+At1fYT/Jef7Pk5mV
# DATA Vbg0uqe755YSyQYKVVl5zyefzPz/plRSIx0oe1yprYcx9UWTqMJ2ICgmMJQlb2d5zKlNLLiw6Rm6w+SIxwcDVMWa33s7OZmJmYeM
# DATA lJ1lA6ox2LFWiprUU7klgxFOUaVWjh5uEElFHyeZFC32FKZs4j+MonneqMPBALb/JEFjGAz4+hECiqGQCOElzkwaPRBOVvM+TPi+
# DATA JZca3R6lXGTIS9OiEOgcER5HupOg6vMBept4IUmgoO3mQjm2pMrN1Vy1Vt0qo0dkLCKJJxSYyYoRT14KBfkexdhsXMog7oHdeEPp
# DATA YDwcL6ESSmN9rnQYIoo17010PrL3AEWSYlyMqG9R1ZXeg/Nb/JtUKWXtX3mas9tgs9MMZ0cz+daM/avY+tdg6heNJrL3v/O4nzwi
# DATA 8+VnwNf0uZZW6coTPPSYLJ5kMqn2I5oLx0l6kE0p6PEThPt4GqZUGw7qh1jhOErh+jk4DtO9anUezqN0/3CQTOgRuUR22f4h+q8D
# DATA vzN/dMevtVue/IKw9g+xy5y6/JPqSRrOD/pUAx9WKW3DJ+FjCSaeUQOJF4fQ9q8usXWUbL2omoxGlKCDWhBE0yfhwRjhPOZ7hmCB
# DATA cCOpUuUfPJxR2z0I5o+eSCWpxLP5clGR/VsVPIGx5jFHUb1L31mTv4+HcUbD8Cn9zK8eTaJHhzRaHM2qvOXvYBABE334U2qd8ei0
# DATA qtqXvkzzUzJaMK4eNJvzR4dzMQ4OKCeoz/T8mo+/h1ICB/78kZfRlGboWfm3ktHoPGaLYk5TevVlVZppOIyXmfpZvlQoBlIe1ROJ
# DATA U7tVP6SpVEbhzBPmXR+WsvEAExiVJzXTxHTu5FceW9GkbmqWyY6pleqggvoxW6jYy51Fw7tYdP7J45WEcvLtAKSKqSAOqGQwqgwf
# DATA J/NwQLPBg1qrpVOj5oBUOUZkIGRVsgdjjEDq0eJFrhSla1JFShd1hSnfu5xSszgtXn1MTRs15qBRKlS+i+q+/KzrMhXNE4kH9dd7
# DATA P+YpEg/j1Cp/sm9dRFEmP9lfqcM8kz7w6/VvFypdmyrdhtqF1+/v3o7zqouaW+tYFVdXtoZORCn+FeuixF9FN6Cmeaiiyp+lEldX
# DATA OxFqdtVsnNKXg/qTQnBkq//ksY5c/YnJECsX/G6dwqbKFv8sOmDLiYapJzw/Mu37KI2Hh0fUDdUanLJCM6nX5e4aJ8k8s6kz4GA6
# DATA CKXc/u1QmxTqCNQFKv/HW8tIp86vBS0dqmQgxSs6olH8sR1wp143j9S9WpMeeTL2K+OgMm5U5qoLry6SOT0+9qX3k9dhfgUzWQKq
# DATA gLSM8W463wtqTby60q61jk8qrRq+7FOPXm+qmKo82T+ckCVEVQJuV0RAfqUugckalWqt3mjRo4fT8JFKg98ejA9VpPoJtc8pJbTB
# DATA kQ52i5wv3WmlQVELOOMRNb97QdQoLkEL2Vl8N7+5IW+ml3gq1ynERjnA4pPcMp4gg3XS2p3B+Ek8Papkx0em1jAJ7dBqr6qChMtF
# DATA 8kTmxBXeZyAjumoqwMX5QZ0qcgUTpj086VW9Nvp0ExEZpOyQLqyr5YGL3eU09i9OomjGNdmvtUpV2a+3TLdism1dzX1SY++F5GVH
# DATA 8rIpeRms5qXOtaBOFWLtOERziWKCuF9g6wH/kYYXqKGV/z5hd8iFuVBup5ve7oUycimv/l2YwD8pmx4HxlI5LDXLJzV4gx5DPIFv
# DATA HMWPouHhz6rsg6F0H6JRVn2U8iGIG5TTyOgNXbTpFpBODlmGoMcIBU8+qZFJk+jOsSrMwDbKrtjr0X/MnjX0vcvpLDvwR6lH/27q
# DATA 37iBcvhejSwHeg2nlbtYbdbkRdpsUUOQu0fx0TKNjCGZXx2E7A21wql1gzRvn0hVrcuvVVOJi+tCt/S8L220pgz+Uta06nm15rvX
# DATA 12n1MHdIxSjs3JjsTKXue6X7a9mx5Bd51BkW76KsQ8k93qEs02hOs8K9RoXqORXKXr1CJUvdRh6jJ7VBmA4fWyOLNeq0eagv18Js
# DATA mY5whPsC+2K7OSrv9eYHmP1XB+N4MlxNJt9Sg/u8UpsuaVL62DYQ+AoFhN/tytOTPDzBtnzbGuitbVPrzecWdbJN+rdB/7ZhWpXK
# DATA ietnoQDYZ1dsLhsMdTPAIJBSbyhpPpgtxpIne8Fs39Np2VQSwarV9qRm/Kbluk7dACULnYS5xVPWgGSgGfgxtGLUxweECF+lNch1
# DATA umjbfNWzB79OHdcpPfFilzpKmal6HN29FFoJQ22e1OBbMNZecJP1Em/ixZxVE1GPLTUx3y7RAoO1LZDDks2AjwudlZh7dj/vqTq3
# DATA pQ6olPH40Vw3o7TaQkO6o5MxH5ZEb3VAkzLuRXWMDigpi1OTRh4Ja7JtvWBj11raalbNL5BuRfsi11jaTTt19UPcVeUFHPWW3I85
# DATA iR/vYG6U5ijUc9C8KR5Ej+0sKc/HdHPUzUPG3ZoUCk0vjywjykS9vsMwIc96IaYbNB/coZIU6oZnvgX4BptutUHYY0qxv/bquxlo
# DATA xVh6c2tgVj9lNLjPjh6X/AbUQMKjsndETNstddMUUCCTyLRYZ7rt1UnlhqbZD0u2rW5JK2NryS4od+FiEKggPZkU4pED35pn+U3u
# DATA KaUp5Blddt4Mw2wcFTP4x+N4OIxmPyk0oH8leMBwtnhCze2x8YM9YtPdnhthfpC/r3lB07ezsrupYZfcbuHs9ARu6CdYG5FSHoXT
# DATA eHJ68BaZWAmNy5XPXns/7uu97x8ks+Sz1ypT+sPhFts85eWQxuF4klnZFOxeH5Uv5XHJK1V2WpXsdf1OrzC75SasJlEXNdfD4ujI
# DATA MQ7UxCcPsWEP9+uMzh0MwHKV7+axtFqfVQdaGF/VDQW3Bs9UdvNPUo+de6tLM9EN1aE2jyeTapqcXGxlK5t6Ec1NqetutJn/hE7c
# DATA tP+m6qAXcOFxeOVW8IR/0gVHXeQknGdklagP9gTaroE8MC/GlcVQpmWcFweITWEc3akyLrbZWk9qFIPoMffk0oEf+HeqPo+Nlo/I
# DATA MhrEZkiWi/lywScSypklcyrepV/Fss0aaxbH08JFkj7Ww+46W1ZqtO7oTIV+8q+n0TAO9ywTrU3d2v7jjU4H29PQaKPvVV6FYmtR
# DATA Nsnq6MSVRU5RYLor2WTXGZ6fbpx/lhplAzNXOyuL80njdGlxX81zo0sZY9pY3Rwf++Xrp5ANLDYUZ4g7ZsuKwbB5Wh6MtI+xZVkp
# DATA +sF79lzKrp5ByXzWZuxqvWg2uF5wHla0lbsxPuyWEdcLj+q9vHAKE4pA3HRqqlkcHnZP/c7J5U5kzfyHO3KqSibdc17SzKppNFwO
# DATA omF1mnCxyFdqHevWxDjw71S+cyCbPuhDOEK7CWfxNHcZ5eP8IS+KxGt+0dGQ0zm6LUozrOjFqLLDQ+xjLk1lflguX1mps3oFtgLU
# DATA 3LBP89OHZrZRvunJk8KKod61hR2C9Md7NJ3MeO0T+/IO7tw5OTmpnTRqSXp0J6jX63fUBi9sIHozeYQb617dazfpH172RY33ZAMg
# DATA feeLnnRk+feUn/MDfB7REMR7phr1xrDZw8bHe2+wXAnvFvrAb3t+b9wIjrvfD5rHfn1M/+1+32//rPDwKBg1Rg15GFEsropmNEJG
# DATA T5/ILk3kaTLPKUgman8b35hvxqKK2z/FL7xvLt9dpzY/mav2ovNBvqPH7AGIhrwWfmo24FlZ0qt7zWbLa/SaXtCqTxr1wPO7jWqj
# DATA 3vH8ZqOYMcP2sB/VV3O10/Aa3caP/E57EgR+tdfyAp8er3eP6e/7CLpVD4pBRaORz3nM04WHnP5vNVuteivKL1ZN0TdWXopQu/5x
# DATA M/Cn9WrgN/HKaq/HkVER8XypFVd8QxDUvaDpH/tBY+L7vtfq/ijodX/2QbPR8xo+VZ+gO/HrnWqz86Og3S0mrzvoRWG4EmSnRbnS
# DATA G/tBfVpt1+mfY3xs0uVGszv2fbrcatE/x/SxFPN+u19vjtbFvLmxpqrti1RRD3Cy8LHyBB+oGn7I8/sD1VgO9dT24FvtVrvfwAXj
# DATA faJH+H+HxqBZvRIcfCvyo1bUOVQ+toNvtXrtTqd1KBbGwbf6o0F3gCfY7Uw/D9uNYHgoy/sHn732IDpKIu+H79F04ZNwTLZn5T5v
# DATA H8uoK6xmURrjWd2l7XQ7uqcadluSyZR36QdiTXpB0encFUPA3G5GIzW/+V5EbToOKxJ0aWnusOwIg3FW6dSaxyeVjjjCOGC1U26X
# DATA 6f1W/xbNVIshlh3ltpmnCmb1Ae1DL44ThbvmBatSTE6+AePPIMZOoseXWB7I1wLEA1gyi8RpVb+ccePBRVveiFH0CtQ3GrOF1FZW
# DATA knaRcac8eyt1jM2Gm7RUnqy29Z+iqX/2GnbvUScRDxa8k3zGGyC9v4K+mHf3ntkCWft8GaWnD3hfQJLuZfvWvebm+2kantZGaTLd
# DATA W//c/cmEHrWeVXv5/iY6hfSifgYtvIbtgBRbnlt6r3ufvXZgR3AaTXE6W7BjH4TzPQ7UsMJZzvhhdFrxRuFkgsq97z3GgX/6rwQg
# DATA Mvm8p+yBRAJE6vcoq/esSL0OjbL9Q0MVZroKvXQ5mXjf9fYkFrVxmOFl+3RJXaGg5MqBFYEDD0c/RYuAxfYPvSc4qjwYU6zUGy4T
# DATA Ih5/YqeaD9VLshUq9rF+PJPH9Q+HKi8K6c82pL8i8UYtmR3Fo1ONrTLZgi02a9IywuHu1UiGp3uYPO+booggUPtXe5+99i3x/H72
# DATA GgUNsaFoAkRrDXer0xl0I74dloIcJycbwxRj9NJhzpbTvXi4n6fmw+W0H6V7HOZnEP2jX2s6NwuPDtUm0j2Rc0PgomdBb/rsNXy9
# DATA Q805nh3qYy5yxuW1PPbLFNH/4cfv12TH5Q/4eAh9h3qb9yY09H6McH5S8R4j4CcoDHk0tBuSPP3OJGK9jM9eCzkbwhp2/0GzJp3g
# DATA m44vWhPFGJcGk3jwkNoUtp5+Ek+jZLnY29tHG0ek0uiYjIo8UhQOuO9kv6qskKhgfUOXAmYTeLmdT8kMG5r3RjMkHGWDB1gIbwqh
# DATA j3eOKdLvK60VCiNb9qcxFWTFi4652O7RY/yxBtUY+vu2bMzaU0XNAdF0nKZCPwK9I16c7u1T+DPc8ERF9a8QvR/LgYvwOPoJRbJG
# DATA D74TDsZ7avMnv2hCRnMWihgd9y4UIXxFfH78E/XGfyU9YJzx3z2+gd6on/vxT3QpUf5jdzx0OfclfLl+ykqWfH+NRpXJchhlKhp5
# DATA h0i/0vvMJrnFfS1tjxK2tr4hag+40e6dQq3TPFOs/Hjnd6liPpDkUAcjn3He6Mmhjupe/viasuH6gvfp5FxHVunPO2QHJUDuIqOa
# DATA prZ7x4gF2MF3vbW3H3g/rtX487Cy7g5TUGQBZ0gmx4O7VysxEulCFqF3y58x2Wr2oS/nQ72ZvLCBX+X7m2rb+/o97ofyjITFW9oz
# DATA tZ0dZ0LJoDiOatzCn8i/xeptFryKdTx5lFdwviXTxUY/mUwxD28uQnmYytCEgkJEICs2wGevrdvJZ0eLf5eI8UeJABeDBJ/XB/ld
# DATA 98TybV0V5ZM3dh1VJkiukWvZL9uifaDi8hkkPKdke0htM1HYVHM25KeOgKo9+ivZd7MjmgzC9PHYjPfMe+liqZbp1rKhXh2aAxXr
# DATA axaqTV5vVN3R+QNz1YzQ/E315HIDjfo0t2JjjG/R38vdvTTN90TL1GQ/ZzLrE3PI35Vc9P72bynWqBDUf0336E/yfnISpW9R5u2Z
# DATA LKaGkLH4mn5l4WmykpBwrtc4MUH31Q89q0EgU4uVji7YVYNFFyHeQ9ftTrMYm7wmclr2vb/+a29PR+3uXR0TRIoDMlXA5Nvduyop
# DATA qL+4RZb16M3/iqMgzY0/7ktaXn9dCkoZO1g51NnPX3JzB9/25Y48WMkP9I71fERSSkVShrjBBCK/7at7SsOHhMW1lGMYZTxwUMnr
# DATA El3TGLkdoS1alQLJMeW4tQEXHqIXIY6qmlIm60D2izUONyqLY2//7j22GT977V1zKAzN5PU9mH2fvSZNj9L/HfnOc0Bu7ovkXWyr
# DATA 2wv2X0eC//fva5/R/2Zv61lykizY1eqFC8+nGcvrEgAfNqMA6KH17yHj6U7x1vxdPr/r//yT9aCO0A7PDabSuGUGmB/IdAez3cHs
# DATA iw5muwPZL/WBbK+w3Vidg36uD2obzxn/XDgBOLGObz+Ys1oeRrZ4CNiIPr2d387bivmc3PN1nvtFOdV4kXCL7Sjl+IvH+d4b1NOW
# DATA m6FeJEM0zEpFV9a7rBU8uRBO+FvxoHp58Uqa9CBB5sqbTmcDHQ3lx773g5W1LzZTyR4oHfy3nuEvnA7OgPk9LtoDKnfowVB5wR5K
# DATA F6fYVGyen4tuQDYO+USsrlGe2nBB00I+jrzs07jmwavrYQ5CYX7O8eBdSnGS1rwfzKMZn/Md8dl9ekgd5ufK6lFYY9Q6qpOebENg
# DATA DBPupjeDsUABzZRuwI7KO17Jx611BPg8MUebrAUyso9wLs3I8PwNjjmjwuF0NxMdvI+Wxt3rzXCZ1Y/kHTH9tJzDbMhqHmwp/jFj
# DATA kyoZwclDLWYIS001GzKXE5YAGC1TsiKWq2oIL+dhWxOCs96c9XaR9VasYU5fx+nrXNZs22gg3pTuzgNsYbPkIPAa+DYhnGcUeJ6d
# DATA xtu24RK7+zxbrq5gyfH6B9sfWBRRW3L0NS5sdEJix7JPQGey8gLuTfffEJ+oboAzXo9CIUlo5jnTXeVX2CvG2z9qLd5EpDWsKfm8
# DATA IQoXpyHvN2qpzSTRnHcf1aRnv8NxLEVVvBCmOuDbDhHVT5l4mgsmmo1a+xqjKZ4R+ll7afjCG+JoVZHS95hImYfeSLjDzyMX4M33
# DATA /IOg/sadRFmF5Xta6p7Wlnv8urqJPuR33ZFo5UlRtrrOTbUKRg/mzWBhSx6R2cBPsCGRTum9vCdYpVOthmL00lUzvyQ9T3zML5rT
# DATA OL2QHLgjQWD+pHJL1mntUPJLeoeauXLPMjhDTMisDsCWpmKjUZr9klIF4RdjUH5AgyH1z2I0aq+11f4xxkYzbvlsKJqBNk7Fjqx5
# DATA 94dDj8/EKrMg08NnbkN672MNRal6YiJgRtolZNPF0ctGqRji1OPgjdiFQW+bLycT/nGJZVga1ONUG/8/zCJR3hERG9H9ifsxZbFI
# DATA zGsRKV3nsWCbcRTILIFhwaY0eiLMa+IM00JK0kw6P61yxfb6BML3Vi+HMbAfsV4mZxp38FIkXBovv9VsD4DOcHaG80WGc8lAcpaz
# DATA s5y3m8PPgWLlJ/Q2bhyZaOaFQ9UacrO5pNmIwcXovLEi4sNoQQU6OxJpu6L0ojDBkhHGrURJQOZKiaKHWDaSS/5ZbFeUUlBbFt8Y
# DATA N1h/Tgs568ZOMW6Iy8yIVMKCwT4l6C2GEl0Ww05GI2z/gkwf9wWZN05O6GePSkiGS87rmqeMC0haUuyOMe6in0lG3DFwnlvyleKz
# DATA 4uQUB71FyN7M+ymGq4kZ6UyK7KS9z065cEA2DoQ0T6jHylOGkbfKUwbZEM2o03CS8XYxWDpI4hHZYpnu1YZUeGPqzbiUOJlyyodC
# DATA mLGoONyIZDodydxJjBjtL0umZDUulLpgCKvgoaeVQrak8+3wlHvi7QlFGYqrEmWs0/hA+R9HUUTJGsYjlvaj2R0MNQgcYg8j9iFQ
# DATA tVrIFgymG9MvaIr4hU1A7xPG8HjMF0SAbFkxUxaOQaqKOiHGousvT6VSny5Qn7FJdEsiP46yNQkUs6JQhVcFVU1VJyuV/ZYnUIVH
# DATA JZugCfKok0brjFgUaUXbkSC8hcMYZ+9koBM7VYlJUu39GPovQ8pEsgvZ9kPyYectyZjgJx6Kx1W7lBlShto9lXeKPamn0lrqdBSn
# DATA U14cWTe35UR9Qnkj83Eweuc4RkpmklFbpxZkrOd88TsT/7XcT/nB1ZFMATU9DzOxhbl38j7Q4p7UuzLsgU1pBeI2PmRqPA/ZPMbU
# DATA gAxfKulwuYjRbYQp63RNlfIkq59KhwIulLiNyULAdTWl2Jjav5klJ1I/0UqoiaCPhGCrTvDbCYe/wL5K5La0RUrQHK4E7hp5bBO7
# DATA xPIroPFTKWNLQzwxcK2UpwspFTdlH9lIlGGSQipyHJDGjoxwRUG20A3zFGF2WlaTNfMJW1bWsvPFZn4Jrf0nTyqGobM4Apw3PbUJ
# DATA Ov/f+a/O/nD2zdn/OPtSMXK+PPsz/f+L8996Z/8Mpg398HP697er6Jz/Sj98RTd9hfsZfvPn89+cfenRl98ZiM7XFKhc5q8A7fzy
# DATA /DcV7/zv6Dl6BreBnvMNvemPjPH5B/pBmDp/PPvq/Nc6Mn+hW/4goB7AdhxL5wWYzaBTxvEl6nD69GdREM0+ihIKJ40H2gSree88
# DATA mk9kfJ5wjxhJ35CN4zn1FhPLG6E7R6wizqPcZ5DPhZLJRI1P9FIt87sVqoPlRBWeaikOrVOc3+ge5LbBOutK5ubwOnnVMbfCpMsv
# DATA lx+YiN60uft9+c4j+jUTdnhcU8N6oja3YjB1gJ0di+36ETtYe4/Y+kThVHIXIxu/yD04ZLIoKhimYxpPOB9Zbj9bYKZa2q2skZoI
# DATA whxKiRcrfJ2Lq99mh+aalvWsMDsXJ8NxdpwlcBOWgAbuXNEAeEWcm7c2+N/I2L/T0H/Zkf92Bn6pnqv5kDN4nr/WdRMwHisHGMVT
# DATA fPWa9K6CPOh107laSVSFR3mW4qUKfBNJ1mQqbyqeksD20vHpYjzlUOSACWfQrggeVWT5QiR1xBPGyyyxUguV9AVye6H8s3JMbhQe
# DATA JxgVFGtGxxgvELgJD6f0oLYY1Lm6w9xeEGIRfD8wI07C2cJ2iw2SuWPsOMaOY+zcJGNn11Flp2nOrlbyLZv8V7H4r8Pgd7QdR9tx
# DATA tB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23G0HUfbcbQdR9txtB1H23meaDtBK7wqbacz
# DATA ao0GLxBtZ3XteSfmDueuyj3syvT4Xe12QSGt1SzlerPdLXJzoqg7UmAjHG6k6A040EabZUAGHGogwbBUht9sFyE+DcrwNWikTtNr
# DATA BnUPdBu/1Zv43boXtEvUnrbfanX7q6ScZsNr+r0f+b3muNk9DoLW1O/4Xv1Hfr0xbnaOG34xCoNg2Oz31ySi1a3nifCDnklEoxhA
# DATA 0AuGrVViD2Ws1+wEY5WLFj3HPLBCz2lfgZ7DNdai51DlL9BzWs1ueBV6TmsYjfycntMO2n5naOg5g25/NOzl9Jx2u+V3b56eo+p4
# DATA lauxGRcaQtDRw23hpnWOqgaPI5Xe8Umly5ZUYY2pNRgf7kzaKb9NObht15aYGOouHC24HtyOHeIqbkdNNLvGWEUZH/JOjnE4TE4O
# DATA 6h68G3VPl2QB0MPtevUV2u1uTPOOrJ8Ucr10U2GtTIbzEgzncMN+gNXRSlGS1nlqZd12S8iqq1FDm24oec1omvhd7EpVfcZmik+h
# DATA tC+wEQuZZxemSoyevMAKcZQdR9lxlB1H2XGUHUfZcZQdR9lxlB1H2XGUHUfZebUoO/FI7Dese6DGP7a/Sd25q0ZMNXDJbxWui/uH
# DATA TyxMz2PJN2TGXQ4Gp45MMK/TE8DvfPba66vvUJX6UA8o6iWrN+a3qAMadBfbuYcKEvQhjnFJy2dTfnLKp3P0W8tRqnn/Tp2Btw6l
# DATA 8cEzlDVVKBOFqr6BfvjuthH/mrLC2Mwmqbw4VVs8WuRppt7xs9fet07emWRQd6lSIBPd0jkfdwTdHUHf+Qh68UCYO4vuzqKvnhrc
# DATA qLf5PJxRL9XxQmuxxWnY88cCtKjMWa6WooRv42EUZgV0C5+IhrIlyEU80mTUnck5Ya2kwlvpSqdldz2DzklgfUaM5SzOpyRB6VVw
# DATA oc5Fj6/PsouI35rDoGqX1ap+vbJdUQX5k1KDV8Lh+sdcz9xc4e22kP+MOBwTvTizsnqzyrsxiFkaXT4XNd6tO0z3aT+1otAOixKH
# DATA O9GhyX0s7rpJ0F11qRzW99TnzXfL8XpWueNPm+/kPlfJzA6izfdJv83p509bROXloKmWcxc71FZzxxCzRcu9UBPgP7dlXfNf4K3n
# DATA rk7PA+STzvNynpXENtmtb3oBsaq55qVLzo1/+af/aNJRjriV/3OWKEWfMwnnuf6qWkrkPWnpEhIJsNESlmKYQQmetaihVhpTLWQo
# DATA UzifU51kfV3qmNH6aBI7W8jxf+ixLqB/pHVoWauaFz+0yOwJVW51WFz5vOyWmZ981k0jP1htHGe4rJJickYfvaQL7AvmmkL3WiCA
# DATA smrrpYoor6iXLaC//++bC0hXeime91AMVJEzXUCfnCTURlPq2Dx9yi9TJgj1ScsZPJE0JM1r3ns0ysPImSbHIkhBaWDBAQgbHEXc
# DATA raKAZP+wKqdIq1uo0nr6UjEpuLVyMd3CZYvlH//r5mJRXYyUisiBDpKUJiOm5czURFgu8zSnz5qurKssn7x5iIY1FNNBFHxH1Icn
# DATA J6qIinYkS7OzWVwYB63L8QJG9NOXkp2iWyuovF++dA/3280lpft4KapPw3Tq8e6uvIs7wTWB4wyPoYVNJXNEBcPrF+jrIhnuZ0OR
# DATA 0ohYPRY609EMEBwpATUb6EdM7ogXosmB3bH2z0ydePryyZNxa6XzNCPQ//PPu49Ab2GQjVIZEiwd8Cnb1RSv9KGytLlJhRNWLw+9
# DATA 6ZLGn0mYYp/cHPLJyGjvR2I8qgGGTCQwDKTZoMSfviQK0X0Rmsp/2rWpPEhGC6+Pah+idPJuDWN8n7JoCi0baMYMaOTB5IAVocPh
# DATA T0Psz1E1PkNhpWyPx9N4gvMGyCmoVJCl/vkyFrUaqCCysIoUoFaEvoamUkjGlQqoaASKR9M2As0Vye57Hyba96g1hXj2oXyCSSpU
# DATA RgzQCXfiumCV8M/TsINeDXEXB+d2rrQruNKc5+wV8Zxdltf9XKg7FvZfbsd2y5ybBtIFtmqSRXnETq2N5O7nVAXyBRJNu0gb2t73
# DATA eBMU79VWcu0s77UyopuI3qspV7cZdWxxvmASVPN8I4nNzqSK+I5EDfIkMY6L3MmkqH3KITwFlNvI/OUFXfGWmeBLIQtIwWBnhCQh
# DATA K2thr6k1Sp+b62Sup3klLfAP4emaHQEaKIBx0e0xUuCWsqAG3yjNrAMjJwqzOhcVtZVEPfaZkMW6kNLCvAfWt4eNuNDbPC7UB9nM
# DATA JpnF21WhiTrLG7xoF+rcQg7XXiXj0Q7CmY/OfNzZfLTrmluHdeuwT2k1bjRSb2Yd9gPhftpK0Tnx8NmQKm6DEs57f1C9+NhgYZlT
# DATA /ZTjtdWtK+uF+UJSvjy2aW3RXt6wV2s23V9ytJeWEjY9VXD/Fnzam54ouynLbtZNz5W9Z2Wv4MaV00Ip8CYrxBTVaRgPuT7IQtN3
# DATA 39DylapY1L3gl8ueU2GJq3OmmnReXgTHIXPN37MtKk9z76lTt20qcZnpV+9AEedNBdPTQgN6cRHiWGhaMAl1jp4+U5ZqMrHfEs31
# DATA eCIzTjbBIz2TMhBJaj9mtWrJpgKFRs/gubd1R4K+xR6ePSUQwhMAY7Krpz6FJS59j6w7DsW1zPvKKSYQ7sYCjXriTrJacPm8cb3T
# DATA OK9r+d5CcDx1H0UlXSrhixngL4+VbMEBWQopmRbYgP9RQfy+Ofsz/funs6+A4fvKwzfG8n0D1t+fz74ElG+VDvjfz/7CxL/fq7u/
# DATA OvvaY1Dg787+eP5/nf3h7IvzX9Kzf1SBfq0Qgl+f/wrX6Ldvzn/u0RcQCQUECDIh4iDPAVjI3MC/OBjgi2D1F/ruUXRCtgNPouch
# DATA pGsVBAC9+nQE+Yg+JLs0BoQ6PqzK3ldY3aTPzAPVPfd1p6X77OWcX4MmxOGRkTEQ/0m0WM63IgDvQ+rCGy4zbHah9uwAgAV7X/cS
# DATA t83/Wy2Wm6P/sYXFhJX81kJ9K/PM70Sn0TyOyNrQ97+jLnhQGQJCO0mvGQPI6mGMhF4uePxXZ7SoiTkS4K5FeP0oQOprsAhObX4W
# DATA j9DpMAyeIc7YLpcmj6ChE/HZZTHlYbCiFlLnNlhgC8OSpf/lx0xtPtF7T3RFE5cqWeLMuME0Lj6arWABd6+Wm22dlYb3rOCAuyfG
# DATA QQKdhXB9FoJGA17JMHg1nIC3ZhTcgE2wk0lwaYvgdg0CqaLl7DBmwHPTqm4CCWilWi1/bYiihoux++LhqXeUhsNlqKB/Wb76ABnD
# DATA 4hobowaLixKnsukTS/PH7HrCWhvLImbzaICR35hiO8EBzbjOytyU4Ez20VEGjoAv4wpYTUZVVE7uZ6kO1Tyo2OL4bCiWA3x0TMBT
# DATA cVBsNSR/ntKljNdSVWkr800WCTmyfKPJvpr3YQSAnFyQTXsPljBD0mR5NPaWMyqmhZxh5xdnDiPoMIIOI3iDGMGdh6GdJkmXNahv
# DATA dY5wlSnCdc4QHFXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUdVdBRBR1V0FEFHVXQUQUd
# DATA VdBRBZ8bqmDUiYYj/4pUQb8bRM3wBaIKllegd2IKFuF5vaYFz+vUDTyvU8zX4SBqDkdr6HvtwKbvNXP6Xru3MW/zgpn69a4X+B3P
# DATA 95tet+P1WlW/FXh+06fyoqtBx+t2S1i+TrvX7XfXYfkKUeZ9mKvxpRdayEO/Y+LbKgIm61F70FnzfBAE+fONeo5M7O72fENeqfKr
# DATA FeT5tdvzzZYV/4aV3zu+v9W1kI/NRuey7/fbdnn7efwbO8bfri9Stvx4c7fH2x07+Tbsccfsl0dU8tu9y76/mHv1HV5/GUikNBIN
# DATA iZS+zIJEDjrhsOMXIZHmEQOJDOqNfqtXgEQG/Wan3cohkYP6sD4cGUhkc9Dudps5JHLkD9vd0Y1DImfoz6vZw9N8nUOOUB5H17Du
# DATA EFiuDm1zsf1gXqstwoLpIy+j2Qym9Wv2sKgMt4OpQbuoaN9bodh3aitnN2JlIaJ60UNxEaUE9T0qSx7vmmu1tkU19OxsUbd5eldL
# DATA MW/0rBX75AuO1hLQccsOBbUfQdJRzeiHaXQA0cvNlEaTD5VScreYfuVCrmwtL3ammCITe3Clmoj5FOySUxyCo0A6CqSjQDoKpKNA
# DATA Ogqko0A6CqSjQDoKpKNAOgrkK0aBXIU4TsOjuzD1qFfHGTNK8h35qk+yIBMUcvEDW1EArep1eprqwrvYELnn77/+2Wv/559qTDy8
# DATA v1ZngJ/Zk/DDuRw2wBspmH0TToBw/vcXEs5baPF8fGkazpajkHX65VSXnEek5jyXo284VBUKciF6RDfy4U8yBzIa2gqExMIZHXf6
# DATA 3p2+v+D0/ZojXO4svjuL/zRn8Tfqcd7oGX1RREz4IHJ+3FuGle8afc5nLx9zG1qdMtpBRtVEYcQHZJXVuTed7itKom6hM3aA5IJ+
# DATA OgjTrZkLRtGy0yoqSU7jmax71ZXqJK8CKb1J7LfhXzfzFM2gbFeVy8bbCsRE3b5mYh+01kU+sKLeLUS8XmttjroZ7+2o64uqHu0N
# DATA o6M0oqn6BSmwwjIpsK+ZFLTXZn/Dzn0/2JL5GxU6dStBjZYO4kVV57RGXOYh0p2ptGZ9xL1g9mHetFjfZOhVMY6s90/zRm7fwCL7
# DATA Ip8vxR1lC+lK5EnBM5oqkYfBN/dPBeVY6Je07gDrV+jQqB8hI1AZiJjvzcVsGMaY+/Fj0BBmSY2T8FQGHilOHvszLaxxtAxpxFlE
# DATA EUuDK2GLz6mDI/MLR+uVKMiaGO0g4PnyHVgvjYrOsnaW9QWWdclocla1s6oLVvVmttLzpHxVbAWhyS8jfvVD8PeM2hFWsXOtI9aT
# DATA gUu8YvSbBF0cTeNszhI03ieGrsLGO+vmRPDMnURMZq14es8GRqVojmX8lB5B/Slb1EWC44rYlbmPhv53YyV9NE7S+GeJkbxRCv6h
# DATA l4Uj8HWilIwilmAypZLNk1whnSWKWDRKzSKiMDvlkXecTCOI8vBsguy+inAyRIoH99JoTQNrDBOCO6uMcgurCEoNHFsVNkwZCrbN
# DATA MNJxfx/CPMUOEFsnlGoPeJB5h2hsouUsZMOG6lXNezOeJahD9IzG7GpDYBY9WrAhyUsqyCDVjyYZ3Faqh1UmkFSBKb/MAoWuMybW
# DATA pu1vbDDCJDnSKfwYJ5ql3KRaFeZsMRZkof4R52JFhrsgEl6TU6WWzz1+9lBqWj5u6E2RIv+asf7rCFLtnAitSMrQU8aFeXwWDLht
# DATA ZO8i25aoj0TOS1pFdKokszBSz6fchUkaRRVM5Gf7eXmwAzA3TsOFEQzLxyPKC6qwlEaZcCo9Jcoy7HKdYH8JV2UcoUntCn2awTfO
# DATA sXlEASzIOIyHoMHWvLcTbpIY/owyGUTglME4QueXWrFZISCxZXWh7quJSz9Uhb20FPTNeophkporMkicygUtsq8mZ8Xn+cfi1Esv
# DATA ThWmVXWeAqn+LO/LmFggNTeH2iuZ/ad6n2/IE5PwVKHDi6ZKRj3h9b4z4CGUcT3DeCr9z/W+AdsU732oxw6kaR7NBvHket/Ce7jf
# DATA 0S1IL6HZPej1vq8lAItRZPYMUcNjW3JGra34rjvLyY0xaF+++ZUj0bqp1e6SwW4i9dJPpC6Lnn2+JITNnt6bYJiWM/vaCaZrlI4v
# DATA 5pdOCgQF0QBmN2RRV3gLXvf50lF+ESVEd8QteIWN5doIz+VWJV/MZKO2MjnOp70V7wgKzfmcBrMwL8QEGFutzDx0QFNgWz9WVFsx
# DATA acoWpVlp7k0oeRK0/S0CuoVaS9bLcXSxkDTq5DSca5DDTmWwpkQ/SiP2qBfUsLMoyzSr8BUy3XLCVT98GKUFvNV/O/sS1Knzn5/9
# DATA WTGo/sCYqy/O/z3jqv6Xd/73wEyd/W4VbvWfQatiIBU4Vj8//0fv7Pfnvzn7y9mX57+mQL+qeGf/k275E33/Jb57Z9+Y0EDN2gy8
# DATA +iW4VvRfx7R6EUi2VIfxPJwNVMFYAjtk3LMMEWRtxTwSDOGagFy56pwwJxOXxoydFtwvjRSYZyiXEvRxsr9WGHnUc2Ts6dqKsHoT
# DATA G2jRTiJ0Fg5gZRug0gncNr2qXCI3x66CJPSw9N61yCquYubGt7nC3Qysika9udr0i1qKTcLJMDzlfYRUPx5GDlh1UbldO6fqTTQD
# DATA LoF5lOKsKCvW4zjeiAHbcvrSI9sdWiZqFcTagqfX+yGWf5RGwziCNxqMAupToxTernw5RfWL8YzMoaXksDddZtKfiRl2KlTvQTyP
# DATA VihWu9TUzfZMqek9K3rVLolw3CpnBVzZCtCYqisM/q+E5+mWBv5rH/d3GvZ3HfVva9CXylhMvRnkn1VjuQn6VDGJ3jiazGGdkOEB
# DATA BLOJXJ7gdHy6GE+xIitJP5ChFkLvOOGy4A9ASyNbZHWUOkzQjN4jAz88pnEy09mRirQZbz3Ammy6ZC1Fiv80Nlyg7ewptTsCHqYI
# DATA S9QRn+mSgZhjv2EwFxeHZRAwnojHgkxMiCra/7BgXvA+QL2JQqGA+CUsoADUFP2DPRWw8/Qa+XKRQB5qwKQuB5hygCkHmLo5wNRF
# DATA 48hOc5ndTd1btNqvYrRfj83uSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhSjiTlSFKOJOVIUo4k5UhS
# DATA jiTlSFKOJOVIUo4k9dyQpNqNZjvoXJEkNRqNWsPBC0SSKq4878SRsjMlaHuNTvfzarPqd7ue32pWg3pAf33Pp3+aPY++FnNoEHX7
# DATA jdYqD6rX8QJQnxqeX+9Oq35A/zTV1xIIijK5PuivA0H5PQmY0h/TwK3RRw0LvdRota2iVxwkgRIVwVVRM4xa0UpEmx3fC7qU7Jbn
# DATA N4Jpo1v1my31bSWeUb8/WhvPxmr9qre8Zqs1btf9D/xm4DW7/ril9eIsBlarGUTrglytse0mxbTh/6jXnNa9oFWlf/zuNKDXULF0
# DATA 8bkadOnL6g+ll3a77UYw2PLSy6COpIVo1JE0Ngt11K93/GBYRB2N+H826oi+hqN6AXU08oejvp+jjjp9yqrQoI6G4aDVa+Woo26z
# DATA VfdbN4464h0mVTY9bJaQimxx9uljJPTkv9TM7cmAzTSSmcE2yA+PXPmbd6APFZxwbeOEk6W3VUCRFfaqQ55HWNk2Rw9FD3eFE2lL
# DATA IygH4F1ivN7y2PbBeyOEyCpB2xfoiQm9OT2lwu2gVDuqaIv5szk5jiTkSEKOJORIQo4k5EhCjiTkSEKOJORIQo4k5EhCrzxJaKQ4
# DATA Qnz0ihJcObk7+o5cGp8OZfUQsB8ybiqZ+SkL2aLkq6fm6mlEPbK6rOlD7yJcJgiNXqccOmI+0KcUQ7l4UgQRqd8fUPD8c7b25/dm
# DATA EEWCsUDv4/tO1973SbIIJ3K+j+/6IFyMa+w32Bu9fvJ69vqputnmDOUnWdxRaXdUunhU2jrX5A5MuwPTm6X8noOD1DiTOsqreXjq
# DATA hfi9IG++YOUTqc8oASMRjnpTwc+QzZtMkpPtZ32n8SM+fjxPk2Skzx9DZ9w0VBp/sRVlmUbZU2ib04iYniIpC8oSpE8ft7zvZcs5
# DATA OtVoqFp0nBnyEVk2CmyU0oCH2gk5vUm8wCJOQpOHjJWwBWQySJfT/iG0YeIZn8fOzKHqEZy9x3x+91O4cAsKJilruouCdjZIEn5i
# DATA sJxDZlvONW9T0H4LNkR6KvvoPB6i8qSNILIOFUAEyaU6i6JhprszSW+2SMVcpnIcJ5Mhn3VFzCmxNAdmOXCUygi/HVGUJ6csFG6y
# DATA zZSdKOuwTDpOpWtVdE4DJnKTZIGk06V+cjLxwkmW8MHgrRLh71L15qYjx7bprVFqFR4LNvfZ2uTs0jfHmT5Ff4K6iO6ZxX0mON+L
# DATA frzmsaJ63pMPsCElgjx6POGTuTgbn9W8t1itmeuupwE1qA4UeYSK1IZDbATisMwxRKXqHy4uEnXnnOM4n9BAYnQFsR0V5989HKXB
# DATA y6jphFN+HQ10XDpKEn6wXEjhYlvNXJ0GFp14c94bVyaxonChWvwMMvUMx8mMovlDCU/8KxwimYYTO0tic547TKdX0zV/U4SokXXU
# DATA +C8tbI5GeN3K5h8j81F4IzinpXe6AUHznG0pgkcoCjZEvVyP4AY0zY0yIxs1M9X20M1izLsBifP73O0bW0mpSdyeEvjLc5A7D8TN
# DATA KNyMojijKFcpN61w04qdpw8bpx83N614gKzIcTgSHT2leO61AW8DUSqONLrMni9v7+giLKZ+wHRY5kJO56hfBUha34z1zF17dMv3
# DATA 9Rdv79sXRdZ+0ES4cDGneHbXxbnZsqLc25Wgyv5GJpRMFjvEUt2eI17V94JJtRI1OzMbRULqlqiJ05N+Lngld4ikftDE0lzI7dpa
# DATA 56KIBtsiuhGEKvNXjFZWS3txaajS1OKsKHZkNEvfpb6FWod3ZObiFa/d/bZn6q03JZM68xpNdc8J/NM0y6eJdHSUoqPkpzQyC9Nv
# DATA 4Wbxjdwd8VelwyYzUwM5jVmtNh6Yrg5vjB7JmomeMmAZDJN6hFWSMmN5Lqsv0wK2mbDK5GlZhcCkP5+WSOzU6YNIq6DtQDl9eWxv
# DATA R99xtvd2b74ztF9KQ/uylJ1nLITKO4DzDbKrBqgNoWHRwVB7sI1eqCRhM4XmmcqnvhCygvzfa2YalYRer5totCKVu5ZntIN4rbWP
# DATA OpewxbcIwpVJOKoYgg5bWctsrAysUj3FTnEpWbVb/I1x4967aYx1G+xSZC8iXQKjPn4EG4a9/3Kei2mHcdHcoQkkZoHRumUXpaop
# DATA QqaiT6oOMvAWLmXyFA0YmpZaHlVjtZjo2vF+gDUrxJzsu1LMRXbXLKpQ7Hj9wrQJ0RjVyzKKQYrjZNieba0WsXwqLz3hLOKWCKPZ
# DATA 7xhbPtY2S5j+y/F9gJUgtUCnp89RURw1LC7s8ZLJxKz6URwVfBIrEFgE2xxRetm6fH1ltDstchAZbgNweCx20H86+/Lsj2ffnP/i
# DATA 7CtAf87+cP4bhvqAHvQLZvj8nH4DXei3q/CglYfP/nz+G+CGfnH2l/Ofn31x9nv68dfMIPq64tGnL8++rtITXyFoj+/5hu6hdwha
# DATA aCNMiELHW76gN9CNDij0/FvUP4R+Ga8Tc2+iaGGnFVkQxCXpaNXu1DQ6An9ZyznLwr+qr2ZwT1m0uUCZpt54K0PorXEoqgaWZLjj
# DATA CFnWteoSbpsktK5cbo4mxBsCxsnc3PipurCeKTSK82763XhhPMHXTBMSqDHbC+Irsog+rzpHaJcSu3aa0H1PwOsAgVcXy35kSl48
# DATA +DH20E492Qle8z5IqAbMDAiRCvEYeu+Q9MAaAWt4wCwL1WaXEJ8nsukjhftwyjxGcdax8SWwRojEluFB26vkZiNmTTt7Vuig7Ulw
# DATA 0CA30l9mpNecoCsO8K+G6+y2BvcbGdt3GtovN7Lf/MAu1XI1B/KNrrfXWm4CFJSnDCJaFEC2GucFPG7YrKk3/+n4Lk3a+ZAT40R0
# DATA AYIAE/PvzDfBEhjTVtSWUH7LNJxR6jKTbkmtCV4wQ9M5dWGzxU7YINhXCxzkRz5QSKOUert80I9luV8vbCEYFpNjiJEhAKWRZJVB
# DATA Ip8KULlijfQJMD/JSNDFeBFVRO/BAsmO2eMRjzxqVQ+FhnJCHQX2DKIN8gaDFHmnHaKOHuToQY4edIP0oN3GlB2h5hfbvLdsvF/F
# DATA dn9a092xgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvIsYMcO8ixgxw7yLGDHDvo
# DATA uWEHRfVRfRRckR3kdxuDVv0FYgetrjvvxA86MknmXYRF1sywFQ1H9U2smXtvDOIU9r+AfQJJiAL7dFikgeUNfF8Rhgq3t+vNC263
# DATA OD8Utkf3ePRb1e/R3zr922t9n65P/F6drrW9wG/StXa106sGzWDc7H0QAFjU6Y47zanfaFWbrXF7XUyawaaIK4DRnaNCBWoGPiJD
# DATA b5hWfa9+LIieLdkYjfq99npEUn2lelKcW0F93G7WP0Cqm73WcbM+bdab1WadPpURRL2w02+vCzq4PA1I6rymAUnzsWhAlIxBp1Gk
# DATA AfmdRrfZs2lAQb3ZbQ0LNKCg22q0w5wG1B8Nm8OhoQG1Gp1+N8ppQKPRYNQd3DQNSBkl6x0fOq0lW0uNRNi4Vt1uhXh0M4ad/N4y
# DATA +MdMlNZNirQbDXPdSrPWZP5PwPyf1fWodjFS2rixummxXTghlONhWj3C1Bg8i/owOqpYa+/2Zy/ozR9VvtWotzrtPrv99iubQ+pd
# DATA Migd5WweDS5LJdI2L7yHKyaVtSK3eXFcLYWLT7ia0Q/T6GAYpg83s4fyHK7YUd9sc5TMXqlDbDs5kpAjCTmSkCMJOZKQIwk5kpAj
# DATA CTmSkCMJOZKQIwm9siQhRfr5xDrWlZ/nLp7jKmN4hBskp7wpjzRdCDsC0IxA5xlMawzzeSuZsgD6yiFvPt6GpSRRqwpxUCWZqeNr
# DATA WpC2eFBM2qhM5PRJC3fG2Z1xLhy1cUed3VHnKx513ig+eDNHoN+NWeuCz9KyC7J8elYfhX7e5DZuQ49bDS6oOlRflWQ4Urk3mF4k
# DATA 0WyeNR1WfsWINHfXanO3bJFm368XZZpbW6SuefCDpIvqvfjCG2LLGhVluScXuNYPvZFwZ2pLSLd5uedj6vsUXojryRt3EiUSuOaJ
# DATA NmcXjS3eHW+RRg9ZK/LCx1r8ItsMmMKgYfnk4rN3JDU7CFW/o+snqqyHKvviqlR/EIXZEqLROFg7CNNcoPrBQiT5qCdJkoXcIMea
# DATA IesTHkHsGf6oExqzat4PeXCbRMdUadABolOdqrC5GSs4TZIa4aE0IXOy5n3MCwBiGskDrLeohP1oODlFQVNBxIuCfDVgWoVj+3KO
# DATA 1EuXOOONI9chDthDw9GM59APJIuN6iwXfkazs2U2j0T/kBWzw9lyhIE4xVxKAgQXaRiPRriy7LOeeoxxmgJj7M46W0+JEFASFjsL
# DATA XL8s53ydvLUzXy3z1dmrr4S9ellt62cs2cPr2vkC7HZt6/s0GrHRyAYk27FZLkXBHIVsi8b1bYv9vBB6Fzcha71ar69d2nqtptNV
# DATA 5a3zRX9tjolFoWyfCGRRrnO5qDWbP6dk0ghQk5eC6HU1703RDaJZkojVROEMJsqnEBESuZcMgxtjRoXgyNUNZhRZXbEWfiYbLiGb
# DATA h4y6h/QGTQy5XMX5gRZiMapOxh3+aimeFHLGGUPOGCr1qc6b57x5xb5zoxX1jAUNmQcMcHEymYjOfhnYrdpJmOUSfjXvXeF0s5W0
# DATA Tp6voOU3T5NBNASNW6TokvTzZSS+nKfhc9+PDdTZ0HgXNIJqJuA0XghqWkZSj7VcOAZLbuRH4fKIRs2PaRjWtMAKByBmiSz3KLwD
# DATA OoxwNIJTjF0lucvTjNPvzTDeL4Rfu1S0iGjaj4YQQRtG/ZRGZKEi8xDKIoDYobQVZS2jfy7PKDjgkKoC/KCsKahMg0xbF1COg78m
# DATA FWepEp8mG2A4ifphWvPeh/2EaFIlpcwNFQhsGKKDARKhPxHhtTEL460TMuSPmaVaKC7ZDNTrz6ng4xF03qYR1v7iwVYY+ZhVrbny
# DATA zBbw4LAX2ST5U0A5ktHIO6IhSydR9kl6kyVl6iCEYiPXY+DVw5PwVBxTOp6qDDPt1uHs43GAglExp3zJRIEb/iVW4T5UsoaQwkz5
# DATA ZIGquKY6F8AaC9Qf5o14fYpAtNHrrFLNI42MLZAJZz54LlQNwSnTssiMSSjxMcgkLP8UT+jnivZDcQJy2M4gTNNTVm68T3kWst9O
# DATA BSSEeYHHaY7PcciSfHkmfRjFnCrxEyv1S7jkjpJkaLnb5a0JNTQaDUfS1opFeDXYN9ryKas+Uh/z3UvDvhG364Z9i10eSwNX+oXx
# DATA DOD4aHgD0O83wbxXcqFq68gNML4/LamQ3sibGO79PpqG9DE0rsm2nEyIOdf7Nj4F9KmhJGKFaB7GqfcQ3uJwNXU3SRR/OaY6Flwm
# DATA CdPhEXzrNl7mvyiMzDcMdQEd5kvv7Kuzfz7/+flvVnky/43u+8PZ7wT5wncx+QVUmG/O/kQfv2CWzFcVz/Blvjr749kXwNV8hZ+q
# DATA +qmvPPr6hQ6KbqMX/vL8VwouQ/E4/3uPGTO/A5sGFBoHlXkBMI0zzexa8cXNowQIaDVyL0Rg+i09XxO/xxFv28Ygp6BhrN3L8sI5
# DATA ucsMfBQ9PRQuZ8OtlJn7fEv+ZseYKczmTM9w25SZ1XK5OcYMJ9Dc9T0IiVNeT0bl+4bQfjZAL+z3XaTh6XWiZagNZGRjpyJgTjMN
# DATA WGM8E0NBOLjM9qK6dqqM6YSGMZnxfGJPTB0yX/EURO7jRx7XC+9j3h4gbtsj7I9ct6lc2IfQaNdK3yizWbRgTXPs/aAxPFthyGyr
# DATA eZvtlJU29Kz4Mdui7+gxbkh/qiFd42SuNJK/Gj7Z2xvFb2AQ32kM33EIv+kRXOpiOdn5tsln2GJuAilTTmhOljGaE3nMKTejUCFm
# DATA 4H5juQF4umZUpJms1iIZhp8hwyrQE8dxyrgYFJbGylDKwwwXcWTcEIWxGioD6yUgMqewtti3KyEeyTYzTBPoY38iHrejNOLzAJLt
# DATA equb8q3T6A8pBP5+IY/kEOM/Z0lq2QxFzEiUOliMg8U4WMwNwmIuGDN2Q8JfaNneqnl+JU71Uxnnjg/j+DCOD+P4MI4P4/gwjg/j
# DATA +DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MI4P4/gwjg/j+DCOD+P4MM8NH6bdafab9SvyYUajUTAcvUB8mPKa
# DATA 8050GDtbGnXPb3XGjU7jOOg1v0/fiznS73Q6zeFqdrYCz+/WKUM7x0Gz/X36XnyO6ma3r7gsXJZSVlJwp8JhCQq6Es1esYybzVJE
# DATA +lGvUw4wCBpXDXBY7wWd9kqA3eB6Y9ho+tcbw6ZUneuLoV0oVJbXkIdWoVwywA2lbBXKtcTQLpRriaFdKNcSQ7tQGhL49bWUSwZ4
# DATA cUu5lhjahXItMbQL5VpiWCiUVvN6W8olA7y4pVxLDAuFch0xLBTKdcSwFVhtuVcsZb9RClFdSFXulwf/dtQoobjavWbYXAtLWwcd
# DATA a7UaFnRMwk8NEswyUnSoK/y0oPV0AbS6PSuAVu/yARSS0Gs/ZRJ2C+AyPDOx0TTPTMw9i2cWNtvNRlTkmY34fzbPjL72olGBZxZ1
# DATA h2F/mPPMOv12u9U2PLNhe+CH3Zxn1h00w+DGeWbK66E2NJiZkDjjyZZkB4XlvdCL1GZ+1uWVyjWL/sWQyxyz70VkxMZhRWJS2ouy
# DATA JjjbEcmLPMXQ1brvxdEw05f1u+T07TQ5Pop2Wypq7bI4bYVaXnW2fSa6jhTdzoFM5FdWD/2GtUis7vWDohdGV1feYzkOh8kJL8Rg
# DATA xa3u6Tpn5W2PHRY8KzazuQ376fQkVuV2fTMDzc7TCzwaVm6V6iRPlgMHQnMgNAdCcyA0B0JzIDQHQnMgNAdCcyA0B0JzILRXG4T2
# DATA WNXumArurkKZ4TMlusJJUhdxdA8ZIbeL6uZd6tiozuyhasV364fxG/zEYfz66/uPcZFvO4xHeyfxjKwrssNO54vkuzDiPwYUY/oj
# DATA Dmf/sW5B87sMWmMQyF4z6DV77U7Qa9/hKO1/h/+oKPTvwgb8Ic3eG4F0vP7+4TB5LO8ov2Kvv3/4hGUz9/o/rv/k3l161/6hSL7h
# DATA wrc56Nf9wycRGetKC86Ki/DfOMA9FY99ulupj86XNOqpbu+JRA+V4676+adJPNvj3opyEHw4NIbX1Y+yQLu3F1b6VBzh6/0KWY+5
# DATA Ja9SO4nvbrRmJzEKZhLbFfKuNA8qN3qTpI1mjngt2/gyI8ABcrT7ObYSzIZ7k3j/UPKo+DuvStPEXXXF9/z6fvEGDMEqPm/h3pqc
# DATA nqbK9kQj68zRT6es4pRVVpVVzGFgp67i1FUuqa6yURT7BlRXPoYcl1YAmSSs98GaXUZ45dkKed0GnY5NAboqniAvGXFiLsDSqYfy
# DATA Hkl9L6jJrhDpfAtI17ZxdP4WGB2bL6j6+ID5B4qiBKNT9+QwOv3QCiOuLUE9EhNpM0uOx6R34F2/6E5f1IDJAr3oRlbY/eQkmlAn
# DATA esG9QV3dOyMTuHTv7ug6rt5o5VyiLyy17m80o0HGo4ysh2hopPaMvA4ZWUYWR8z3stQOk+R2k+1hERsvS5YpWL4jwalAf1usRmg4
# DATA 5Hw68VqQkThTMj6UxFNPHbo3YjH0zhW1mHHjnq3/Q2lqUMFMdKGwRWbnprVRV5XAZCfa3MugGJKPJc7odEbnqtGZWxfO6nRWZ3ah
# DATA PfnMtP4eMGqII8kubiBHUf2N0WmAZNN4kCaWBN6SLVSlfxdS65oNQLdY1b4zg2LeotRgqCElLCU3SKbTKB3EegxkyzWNsNKCjQs7
# DATA a/9xyub3Hoi3qn8Kn1mEXSYYRg1ASdi/NJhiL8Ua/S113m3VRFXuWdRE/qSMU2Vz6B9zA8hc4YPPQKdFHI6Knyw3iOCgjvxa29P4
# DATA fMEJUp+Llqd1h+ko7adWDDs4TdEWwJqS++JtdqA2zt9mA27TXYMExA1qLsd881v5183PcCXC3R/hwxbrUgZmbeGJC9U2STBIbDHv
# DATA CiWMPR/SoNXRzhzpQJ2SYXewx1pWd1Re2nlRwgHxbhjTzsUZzLUpXfLtwb/8/P9um1SUo61yVpliSqqSKki6OBVjjOw7HpnA5NGW
# DATA JA9CNO2rwu4a8nzRuz8cQhqPnhYW0ACNjWo/TxSZnwz2Ch5k809GRyaiaGIybFN6S817M5zlVMDZUCal8tO7IMLgJY06DbKGEqSP
# DATA nVwpX0u15wrZ29ycvYW6KLkMe1lseErIIpzofL7PPBkaJOYVyTU9seZcC7EJYBFPIxvKNp8sefZM88ulWPRMQFIefe9+PEVejcha
# DATA y8aAVbHpjUt+gK/zJGMTvea9A/giXjOMs8EyQwFxSLIoeR25bNrbZfN3c96qlqtzFT0+db0LfNB5+jb29oRe4//8UwOspCHlCRYP
# DATA ZuCZnwAfRHVrSXlHZSFT/MzzqUB7cFrI+ssgojlIzfuIumyaet+Xii3VFwQo5iTxeUUP7o1D7037DpwhFHcJz6TVJq+a9336GnFF
# DATA pvK/top85Sze3kMUsvlTGmhpkkFBpDqPjTk7ooZfFT2nnAUG7UCqX6hMc8lDWfHJpC+Qu1FJ4acJFXocE0J58ENol+JkYMa6paEJ
# DATA JJxpKFVFXka/YQlF4saZfhSL5Cl4ZMdxQi1EPRxKz/N8dB7tS3Ue/3YZ88qnHrx1IUgGU/2lMQ4Vmysg20DaMJLpELLdyybxnPKT
# DATA Gwf3LQCd8fSmz/qm2iMIBVWM6qLEyl2TdxQtpOg4C7GQmCXTCBeOlhF3HHg6nslEhfqlxbV0Hzc/+L3F4xKYSLGp2qZbFLfG4iSR
# DATA DlmyFr1xJghNEUqO4pRGtxOEousxy9jGRuGXputo+qlq+WQLsqoz3kldE04rUm99rCZ3FDaemCZYyOW5A3oKxk5I9wKbtZy5RXNF
# DATA lo1tc8Vckcy6Rw1MLfBqIWEZv8VUtMxXam5jbnhSKLWLWE8vg8sln205l4tzuawhKDgvy8vvZdnoQHmuiAqFowKrI+XEZi14k3iB
# DATA I86shMJITFAs1WjCLpj8QT5Pwhn7rBEMz7NW+UX8JOvgh6xK8tGXe29QR1pub/roe+F4XVfO8lnn8uVCOJHusIyTWDmSLu13kKB2
# DATA yNtOZwMdFaXymPvdbDF7Lo81YA7rOf7C6VErMePg3gO2yU0VAQQ5nJ2aVavvJyfAIZ+quvNdjy8s4Z0iq+q73lt0f0SdKYwhGCG5
# DATA JfxdTMLiKVe4WXYis4cFNtp5vHTM+vuxIrpqNhVgtCHZZuDjQruMDK9+8iha4UUVa8u7MQMz2QFJ2bEcLCiRUuyvwpKTzblMmMdt
# DATA Uy7/M2Mp/weQk+e/9UCkPPv92ddnX6wSLkt3/iUHXuL+inf+C7r2Ff33m7OvvfNfn//y7Es8gXu/wu1/FAQm3f7N2e/P/wPglR59
# DATA +Dnd9ie51XEsXwCTzcvY75+qA4imr0eieXLOPUHNk93yXraUCatsyGdurTzIDRhjBg8m7BGYyTRqhAkrNzj4ybC0MObN81solm+K
# DATA DJigMhzCsmjCSaO/bYBlqUhujl4JO+DY6u5VxWMKuvxUfkJVQfPEx6pKogrO4BG7VqAl75YYhxn7a4D+UY5yZcE4qOWuJXjteMv7
# DATA sEuPxFYx7OgKd5tDONg0IMj0WWJovx2PRvEAG/KxbVl23ESaAa5vnUUUBv2cirt/hWi5Ux3cbJYUW9ez4lrulAgHuHRj/VOM9Rpv
# DATA efkh/hXx0NzS8H7do/tOg/ulx/ZbG9qlWhayIcdcPrN2cxOQy0IaMSUPiwnDtlJJAIKdzhcyFM5TdD3g1I3DfswLf4tMlxo9cXSE
# DATA BZaHVA0ymcdTPVbL3Jhuy8hsRuBJTBUSy19C+Mug+JfuirhENhomIKYNFP8JdfU4w4Y1EIV21LHnba8rWElVk6oFY0EWhDiWLJGC
# DATA UJCHyACsfGbVeZRW2aqjElhOuZc9tMwE3IgoV8lg22g2OAamY2A6BuaNMDB3HmB2mslcwh6+PdP+Kpb9NRn2Do7p4JgOjungmA6O
# DATA 6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmA6O6eCYDo7p4JgOjungmM8NHDNoNyJmbl0RjtmLei8Q
# DATA HLOw8rwTGdNCvfmtnLLYKFLFOqUMb8jvkuNFZFmz26531mQ4sJvtYNxsTqvNpud3x4I6s8BjZRpZDh5rrEDf6lZcS0i1lbjW25vi
# DATA 2u+3u61wJa5BQHHttq8rrj0rrp3u1rgqmN3auDb7Xf61GNeGX/cCqr/XE9dG91rqQGfQbYf+Slyb9eusA83OtdSBYScctlfra7N3
# DATA nXWg1b6WOtBpd/ud/kpcW92nrwNWcBRas90Ztxv1Y7/9/W4Jj0sd6qB1NYgd9aUaYifdsgWxa7ap2+juALEbjlpFiF0zag7rOcSu
# DATA 1Wm3Oi0DsRt0B1F/kEPsGr1WtxPcOMQOe6iqsrqhR9emxa+zaHVdtjnz+y/HpSs7XRv5UmtbnK4cMp9T2c2X2t7mS9VzwjzQ1VUZ
# DATA 5WvW0wxMFNSUq9daocPBp4YFJ/lPg383XLh4RnXK6woZTipDs0inU7VmHWXvasQ4WTFQi7hri8C49sr+go2wOasEttimqzXG8eUc
# DATA X87x5RxfzvHlHF/O8eUcX87x5RxfzvHlHF/O8eUMX47VGxVKjn2elOjvyFc+vEdf7+hfBTTHxuZnr72jjv8NzUlIHNZjkhkz2QZR
# DATA PNnj0JmsJvqZWe0z+t/s/gK3SbDqBwVgU98YDqPDHdKE2+MTPGsCv1MOhYOxHs14RDC4M6eD6A7abz5o7w7Yv8QH7C+rfvjcHLzP
# DATA HVvb1RBZ5I1Ps85ohCLLAgLLY/q+TQvx2Z7Tf8FOrF6kvpM7Km9CG7GkQnDNwohlHYcLVBHvK0APiyFQrlIbyjgwIy300RLeGN7B
# DATA 4B0tAQXrR8wGCy3Vb+ge0GQd47T3Ll1NIHKv1Q9FJooRDUpdgeptogWc5UQ5V3Ul3oDs5zPlOIfelwqBp1HnokdzmVYolemy6uFW
# DATA JaVSk4P32oZfsOr2g4RGurE6rS6bX7X49och5BaNTH8anYQpDtQrQdGTcCJH80NVQb0JEsKcBHagx2EqwhQS+eJ56EXIIqk/WC6Q
# DATA JHMIuqxRvhpHncuG2jCTkmCKDXcQ2ITh4cswCo2UepixSoMS1goZT8On1ePFlui9B+rNJSKHXsREzBLS0BUJApgZFX6YKoBBMskU
# DATA j9HQdDiY9KF3gl6I44vT9lsi+ZG8Zk0mvkIn1u1QnI3sbOSyjVyqVU6WyslSXcU63miN35hc1fdibgNsJIRK6Ekr2FCOPbS0q25Z
# DATA E/E24MDi3GEIDqzHNELOQaVyOx5YP2Z6J3MhJ9w26xchght1MWR3oASL1wnIXuNg4kvsEsLLL4iwft5E2FzII9xaH2GJo4qyX45y
# DATA fXOc2TVmV11UrT1+8R3xTO1fmM1FCrP+nsc5WBvn1lWjrB1mdMMH631uF8Q4D8BE2rpk5fXaaFuxVtVHR7pViPNGIPKby3gytEY0
# DATA 9BYvLhf5AxmGZXQP53z0hhew9VzKgJO59+JTIkodSpI/poci8Ljue6PohF3a7DheGI8qdLDWCMkfpSxUZ8b/WXSsmVdGAuyHql/X
# DATA XSGAayGw6Ng/ywZ5zft3ZCkMed5DPaPVzZLZP8TOIFFd04xMcWVLR8qNhVIkb2bTA1M6mmYIBy5ebJqyvcRGuD26OiPcGeErjuoV
# DATA a8vZ4c4O32ZWPz+ysWqw082AfWBoC7YKPHA7NFaZVnicD3VKorSSq5jyUGMETqHXib1VGHUQ+FwkOzG8Kici2txIgCjZMhbMjBwG
# DATA 2aS5emV6cv5SbtiQwO+jUuhZBI3OQ8dP3oWfPGMfKp4Qb+rmO8WdLFMIfNpCTtZuRcv5B4rt809QznPjkhjJTzYjJHW+CkTyfsFz
# DATA D5c2VRlAadMIxVQCpqbREeWY8c+yH1aQWPSfEebOSn2WamTGN9Jts0VME2ZZgeC5cs17K0zTU4iyJrOiezwNmdnIVusiPVVeYhZl
# DATA xR7IVCIGn3ky035yNXmwG2m++qObSL66ZPZAyii/Jfkmf7WKIl3gzb7cMEMwTs1M5KlYoXlVvmQxv7O5mHWjUMVsnP75kozsteAe
# DATA Qxf0++hiYeSEwmRNyWLXqxyZhawXLQBRiualFwk8myQnk1ORhE5Z2RidK8Yis9RDZc4b+NBBjk2v+FRFuD1pt1aIhV7mkuX48RaY
# DATA cd5f6RYr6BElkZxGYLHSkDMbKjFwLklNAsvb6TAOaRY4ZQN1FC1OaTxdIo9j5bwKdUtWuDEzmedFFxpdcz5aZpZwaPB9hBkp+9zY
# DATA A4YFwliAa0/dNrcl9NbK9cp98IOd+2CqsAu6Rei6kTdj9nb28HSl/9VsGylWWDUiNM1Gxjiaxtmcta+997nHDNlLMAnTI8hKQ5lx
# DATA lmlO/UmSSv8qbUU611EIRDLcAtfSLten6vnvVr+/c7eqxi6yryCvj6SGaqAahppgbZqkrHuju0y0sSh2KLwtfDoO4jgoSsW3jo9m
# DATA cPXIRFRbmHCssDQ4jM50nrJePfW6Uswcj+toezsk7IXoWt++VNeqZd1hmAzT8AQNhHcnTOKRtVCtnGv6DmU9RCG2hVLmQPZe7B3b
# DATA nsGMhgtLmzyD5aLmscvPrGWr7QGDNJwjz/lIqN5PoT1kT1euW1N4pRK9XYD3U3loX36fYo7AHEQ02seDrIjA/PL852dfnP3p7Kvz
# DATA X9PnX4BnCWzln+jPL8CxPP+5vrgOi/nN2R/p/1+efX3+D4y7PP87hmL+SZCYHPTv6cqvmZ/5NZMzvfNfnf89AJrnv2I6JoV99sfz
# DATA f6QgfkV/f0vvpBBw0y/ohz/Qz3TPP9NLvjr78/lvHCbzhXCUYlsauivVLaqax0FnB+KL4iGsT9ODCn8/wmZ3eFEHQNYpUMtxyJ6r
# DATA 0EwRjM819OCFG4xr3juP5hOYL9SZorAQa2XQ5OrAW/mZb01o/JKWiPg5gqbtQ9V9xm0TNFcK5eYYmlwpzV3YWshr6soDuELcpKod
# DATA J+b2B/zVg2jXcgKRsOsEaMaZRAXeQ9nZGOHMbwh+0Gm0cPTMXcruBsiZvErKq+XxFFNdhGYqgOqeFhEfURugHvOxfu+DKMyWavmW
# DATA cmwJKBTTFVBy1Fca33PGnCFvEU8i5bJO2V9OBtJwOVnFae5WJTdbOuW29qyImrulwyE1nV1wE3aBZm1exRx4JZZTb80UuH5LYCdD
# DATA 4FJ2wO2ZAVIvS7lg4zaftzZ1ExzOUvI50XBTM7vQRKYM39QKxXnmHMOJMVE8TvsgDecWLz0b5b8cwKffhswQX47GV2YPo8UAfu9d
# DATA cZz5iG9ZDBS5LB/+p2InDLEvD6pRUKih+HoSIp+sKdgDvPBNcUuGVeXHRzvPMt5H5vEeLrFFtFORRiUkV/xRitbJGyXYbRWaZTSH
# DATA 3nToTYfevBH05k5jzU5ToMsYzbc5BbjKDOC6JgAOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsOvenQmw696dCbDr3p0JsO
# DATA venQmw696dCbDr3p0JsOvenQmw696dCbzw16s9FqDtvBVdGb7VFn1H2B0Julxeed4JsUekzDojcQmbEe5+XgVOiGvTxjg6boUPEv
# DATA QbvIL+wNR1F3NZfBBAwaYz9ofV7tei3fC3zPr/f4T6NV7TY9so+rvUa1Ve30qn7Q9oJetRN4foe+NIqF0e52W71I3lGMc9AM8jjT
# DATA +/I4t4M8ykIWtSpGq9GOVlGWnZ7ntzrjbndS9esUvc7nPYpsu1EN6Id2t+r73Wqn2mpV/WavVFv8aBD5JeZhvx2OwmAd87C5LilN
# DATA if1AxbhjQRibVlKKdXzYHQz6a4iMftdrBN3Pu+1qk1LS6Hl1SlPX84P651Uqi0aTUuh7JbRiGHWa7bVxa3U7edwoYCube1bNqBdp
# DATA kX5z0GxfgdTITU+TGqUVW6RGisugtwupsXAFpMYg6kZDi9QYtoedYU5q7AyDYWiRGv3WoNu4cVIj9rZXt5k0NOBaPi6xjc1D2pKx
# DATA oYRI5cgvzYib3W97+JdMDY/NjTwIPd5aS4zyK5uTO3r9Ayt+a+cSHCIEhW2ffx138xxEm6aHlgFecIWqcr8cWFHcXzkUspQnLcoT
# DATA +rch/xZWq5otg43stL69lvAoxiKlWeZ8+XKptYC1HuG4EdV4YWXQ9uT6WiCZEtjFt3M4paLhWWxpMuQ4kI4D6TiQjgPpOJCOA+k4
# DATA kI4D6TiQjgPpOJCOA+k4kKMQjfuuXxWeomw6BvyRrBmNfHygz7ufRMqfybjHPYWLxAU8IUGhqr6LjX57PiMZB1NhPxYCUXNVKxS5
# DATA cnEwIiIL8WR1nF6O2nvzOBpE+jQizsjBf9hHeRQ5kPnJG3c63J0O3/l0ePmIljso7g6Kb9fdfm4OkD+IH0kTqtD4NDvFkn8shyxt
# DATA 8I058miJpqLJTORQJ559uHrqGUdBuedVZ6dHCEVOZmbhJLqkfLZRtRTXIzdxujmZwjVqn/N2ytm7KGfzjhKuiviw+T70l7jtR/R3
# DATA i2Y2DYoLwR9+JB9fBL1skweXFIl8c7NIpMpNEYh8E6c4RzjWjUEp14PEZhmPLHeqKjgPjtP54LLSlOcUAp6TeCQnmJMFUyAyHprg
# DATA gkIw3iiiejSBQUQTlkQOHnNKNBHlabQzr5olb+2YJe9oTVAak3WGvBlOoCvAWr0cXWpMfMGcuZYlHJYV9UbwLtPTyCleIOF5HZhz
# DATA NDTjDzVBsv5iOZmPwGbXkTG6HVwyX360OV+kRamashyyZZLXkVmY0pzUm9Gc1kM/w2BQSLdiQQIyAzn8BxYNV6loJoQyCBJkzBGh
# DATA z3P098en2rh5hnXk3+xYRz5Klqxh8dPlUZ4fWm16rtWnk+kIm0aAaaBOYI7pFRoE04wUxmhIpgYNZgPKuMk4WeLEW837BBMC1lZg
# DATA pQSx644m4c+MUMdTqs/mXeEl8+ejLdqzulOVHKL5tTfXlySHPkqTY9QBSjPNbo4ig47lTXJUacLlACoc92fecobk6h4GAsEMRAWW
# DATA aQLlfUhF8+LyM2w3H+/YbrhSK+UWC1nLigzTZAn18SWUKiZiPKR8Rhb+flCxhkPds0BpOZaulM0yW4g3lOpC/XU5P25XyvZVUWjI
# DATA zWw3CXeT8J0n4W7G/ZLPuDdOpp9ryTbex2J2tAiVlXe13HuDGnS5hPX+SyTXbKvrylZKa3OoXAgn/K0sf7ayL1IqzCDBziF52els
# DATA oGOiThrf+8HKtko9yV9Vl7Me4y+cmsL4PimQvQCfYNYLK44NqXrSBF77F/KH+Og0DzfPqW7diyTntKOwrWe2VEn1LRgOZgPVFkPt
# DATA X/7pP2kzgl85DkTKTixIbxFNJjx1UaAJUfT6HuzPzDsSKytcMC1iCBU2mrGMl9O+Lq7QS8eni/FUWbNssPLc4CiWn8XyYzEyTJsh
# DATA amZpfnm85xEiXUoauUK5lUa54JxRA9Qr0IIZytEVJ2G6oqlbLFCGGhnDkYlVr6CslhWMs9qc1baz1bZS39zaiVs7uYLFttE4vEnx
# DATA XQY0jZSOPou5I695Ib6gwfvsBeG3GQI45+fZay0rSydiK7JtOSxcK6xpyFI/XX6X+l8++81XvL3B9CLQvX7UdGfmgllhkAMiZWS8
# DATA XwTd28j4es3fvP6iNhTYkZVLu8TWPGyim18x8e1dZ3TVxgv6/QOt/7tIFoUqsffti6JtAjHRzq9ckM11K96NrdFW5qtZMJNdqbzK
# DATA JVU+4i0epilkFiIKNezeG3ImWMVZbU+2nWr5Jel/YkFVzWnsVkbsHQniKeFPYlsxSivvAmxV6h9mZn8JGp8xbj8QZ6pRambk8Mk4
# DATA nkR5PxFDrXaBvTopS96alQ5qzVEu3szywGqFEyaubFyRrW9k6paqgN5p5Q0Vqs/0Blo7GF2q1fdQqpZTuh/bg/NwWE96EM6gHTyn
# DATA BMQ4pximc17oZc8xUORwV56MIzHg844LKYPQNPdrvLBFRkfNUzA7pNAITWfLOXU9Sj+4KC59h/P9VbGeLQgXz9F5DmFzuP6JGVxf
# DATA nv9SeFcgZ31z9s8KzQU4F1hcX6wSuP4b3fYVAF2C1jr7n1Y49IkBW3+kezRk68/nvzn7X4bSdfYF3fgVv+v35/+BCV046eCd/e7s
# DATA y7P/SZUmnDjg1gth/7Nxb23dACowTYB3naKf4Ppm7BgmtWaQJ6cuidX7qGecier3CeuGy9KFlt2uKG7oERr7OOyjn5LZuqhhc52B
# DATA 2Hk/wgxhG2zrU7rLRMihtgqmf94z3DZtq1QqN8faEtq34T/xlmzrrdadP82ouPWNxQp2nYitUMBWGq6gFgglMQ6vdUFxXTta66OQ
# DATA jE78TLFu1Sv1ep1HDcoA6qJq3kc0gBirhwkWPOkah3OsBeud/4uwf4hICo46MxAKFFf0iAYCnC0oM7QurG6bzZRi43lW8KwLE+C4
# DATA WW54v+7hXTOzLj+qvxrOvFsc0a97QN9pPN95OL+V0VxqYyHpto/ueWpDN8HIKiScET+ZYrbbyaRJd5ipRbMhFs36sMxD7CSuUEJj
# DATA IH2o0cSUhEkMltRsqF87CuMJ/JWDEKwiZgsVk4XRNjQZPaUBTi8wx7NsjiTBRUotZFdaVh4yawZk8j6KP1OaeCv6mOoc3Ct0kc+U
# DATA 82lz9m/MsMLHc9glE6LmoThgkyEjs8QsyMxZcUrRg1My3h7BUxYPQ3WSPRLDMMqwDzHOxljHDOHVGAh3BemKR9iAOBhH09Djne9M
# DATA 4ZrzWORQWg6l5VBaN4jSunAM2mmqs6P5fHuzgKtMAq5hDuDQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp3l
# DATA 0FkOneXQWQ6d5dBZDp3l0FkOneXQWQ6d5dBZDp313KCzgmaz3royOqs56ow6LxA6q7DqvBM4izOW49LjjBM0U90vyFG0/W4xwxu9
# DATA 3uYcrzd6zVWQUy9gJJUKyoJLderdXq+/Di7VkEAGccoSVOplbYst1eB48oG5bpEmNew1Ou11z7daOz3f6/fa/XXPd5u7PN+N+p3Q
# DATA L2fCNGg2vCBoV6lit3pcvYNpw29V/cD3+FpVrlV9v1H1m51qp+P5Xd8OmjeMlvBc3WF32FuXg4wLK9X8Ts9rNnyq8Hi1Vx/36qXg
# DATA TN6tBNe7AgKLm5BGYElrtBBYjXa73wmugsCqR70otBBYAQXUyRFYwbA+bOYIrKDb9tu9m0dg0UyoSr/vNGkPAhori36rwkgjI54O
# DATA 0eMDcob7pG04ZXzqBOsAUu1aWReIt5w8LrlMrDFg5e6wZPYbU7yrTPH8AT1ql+eB6+Z82kvYZS+hrA7CT7hmsa1dTERxIUDmiJ49
# DATA 8VGGXP6EGQbXrNiVMVxrPT66ohY9DJugXcZ5rKIDv7E1/eLvF+RT8UVtJIf9ioWtJ5ufN+P0Ba/ZMIXbjPUyFXwnHNe2yrt5Wl+q
# DATA zOvq5HJy4eSSo+A4X47z5ThfjvPlOF+O8+U4X47z5ThfjvPlOF+O8/WKcb5QF9QJ+Wh4aFO/Flgy5YxA6u5KXU+W6SBCBeFadRiP
# DATA 2MhUDfNeqw6DZzEGrOCdNE0Qx7eV5YXmRSYP9dHpkfTJ5rV3S8a0NSdgE7aCyUVF6F/Y1sjlsC/MMRMIfaeu4rPX2K4R89x7Nz/6
# DATA T3b0abamL9g/fMI2+uM8NthqOYpnlB2KasYyokr34dgK/i10PtRc4VKt4BzjNJQzVFzqeGsfe5RpfskvsuKnBHWpq8FJqA8TY596
# DATA JzizqKxP+o0jSNWacx+ndqr6R/rlu9vsDi5DKp88XXfzlO0/LkRGxKhMHLRIo3oTTgMiHmL1Hz4xxvxnr5nAa4gbvdVceJ36KlDY
# DATA 6Bq19vwY5B25UecGnz0qp1cl11S2re2F07mu8HYLhiZzeD0FxPay5Nme2NCDRTqhKd/f/q18xWZA+rr/138t3+lRytPPXnuHEQ+v
# DATA 7T/eYHkro5u6wmzxgC32PSlUJ3Hv1BSupKbgVBRebhWFy6rbP1N1BeOAlRSJWJ+l5L4IUd3ufahluDmlfJB1CWnLeHNC3tZn93Pl
# DATA AYklHtr24ANut7zNC4tCG58qZIcYC1bby5+6g5hqHUI+GrtR4N6QmJQUArXq7eL2z53YxAtwuJr/e83khKIoxnVzE8paI2upCZdV
# DATA yfo0jZXpFs+Y1Ui2G4wZo5JldEBYuSyDBXwCIbPpUjQcTtlPXTEC+lIZVeXhioJRMhNFe0vTAxoHIVv0yWjBcKU0Yjc6E7gUcIsN
# DATA fY8XBllvfBY9Yh+vUta4kGP0cpyTNyE4484ZdzsZdyWlHKeZ5TSzLmHVbTQdb0pL6z0RbKKKrebyyonA1Twn+9y2YuNtiNwrz4LO
# DATA XJ30N/RODK04rm+Darp4ynCZnWUFgXXKyMmEPdoMQMBaMY9ufw0X0yH6NPl0oC4oi1q+VeQPu8XVbT/2K0Gl8RMaFHWMNkjKK6ca
# DATA ves9/sRVtoggNreYvjV/aIUAHDCy4STxeCvJFvBwUwxvcA9Ld66AgjeKyRsfVl51XlwdeUx5RF5K2UjrJM6WRuBsLq2moiTM/k14
# DATA HD6QLlapmYGwot2gaCYqH1jv7WRW1EIT1awQkBbbJaf0sWjAhOiZIJImp8oRapo7FK5EgIuePsHpLh46WXPKcv/VPFNcGBHJRl4O
# DATA FktFYZrEU1zkjUYQrIJIHNMuoN2V6aiUKkI+FbHN5HxqIaVVdJ1ibqlX+I3rUM35TM25WHb+5bBQ82HGmajORN3JRLVtEWegOgN1
# DATA q+H5rMVePyw0khkGukU8zaFMD2SZlAVQKxYFUFLnvaNlECGwiOM7nF30O5rKMOGxGrqcrBYaHlG8sOVsdmr0IHdUcOXomtgICYpq
# DATA AQQdxSCgxkrtPmJ9S3Qea7x16sTxGktV9iiggvEnRQdSloz+MTeuzBWWngByPuJwVOxkz43pljaziszGB4b+yOeiXWndYbpE+6kV
# DATA kxE7BzA6omOU++JtFiZapPYlb77L0rEVjKP5uiXkKIuPOO1v86cttmuRDS47CWyDRdHMN5mNhTLG7mpprFcAsOvcuCSA/fGTzQR2
# DATA yVghsGMSF2lGunLan2oS+yfYMkopT5eZbPfiGjhj7VQlpIs5EMicegU6xiaMEBsovP6SDF2lmBoPat7bMQusLllo15vGGc8eZa8L
# DATA tisxRZQ3gcg1bq28MiwkBiCI6HWp4rM9Ndq+VIMumcH/8g9/3JzDhdooGc2Srmkkwr/wq8aDeGGQ9/xLTl9i7VsyqkVLNZnrU/cL
# DATA qm0p6/ji8OoiFvv8/ogPhdPcYNqPj5bgPirXb0V3d4KKEvpjSMY+S/jGQ/5NJuzXkaNXrKvTbLe6+mE4laoAKes866S2YIoDBVvZ
# DATA 5yuqttCpnkQLILFkd5N52mOMB3ovBn2cAi0rtK4ZlAHRIMj6o+hQ70lFoTYomAby7Kvfv71U5RPWGceeUvH5MlpGOv/exwwOkzaa
# DATA QOdKzCdhzM4cvqCOm0cAQL8tDZLXJKTiZHlF5YCR9SMcLeD8pAycwYXEAS3kKWB6I1AUaahEoV1L1TNd+yUz8r0tdU8NEpKH5RVK
# DATA b5GGxzRunlAadGZ+rI4SjJVAdijVMiUbJhpmyiigXm62YHAcwoJdIvMTasgz0zOoXnVKvUbGc8kYEo/WsmoOl1vESs49ovmvVuGG
# DATA 7fdM8/WTXfP1EybwWctVON+Yt261HJZGR9gPLgdEKCGZGjIw2uTq9UbyPGNfRW4ZRqMR57DdD4T9jMWraYbG7h25R1Vn9KZi9cXo
# DATA bH8qu1lLGVo0EmTPom0kmCuSPWTX6t2FemLHzha16486osE4gX5WCH8plaQuiFdi4c3G6FFJRDZB7z+ffXP+d2dfnv2vsz+f/xbc
# DATA u/NfAIlH//3m7HfnvxE03u/Pvjj/+dlX+Hv257Ovzn+7StSzw2FW3i+Yxodnvzn/NZ46+5ouMm9P0Hv0908e3fLl+T/Qc385/yVw
# DATA eohBP41Oqga99/X5r+jvb/EzE/f+5NB6L4K3RmqazZuXKefDGK10JtuCQWz4ofHNiPI9zDGyGIZQ+mFLQdY38PtDvZ0kjQbxXNlc
# DATA 2RL9Ebf2acJi/VtJem9JvKwG5GB6tpcGuXPbHL3VMrk5lJ5UnXwl8WOpSiJ5Ur4ZPZG15hid3Agtm3dUz9WhC8oKmTDibdNotnQ8
# DATA vR3K7NqRemLWc1/OXQ+8zOI365MBoXs3see5G/sk75aouiYnCuqjCeessyboXz50gEKLp1Oc0QFMiArbwIgvVf+2YIDLjepZIfYu
# DATA ToRj7Llx/inHeY3Uu9Lw/ooswNzK0H4DI/tOA/tlxvXbGdalSpZzwELrPcumcxMkvXJS9aKIuFRDlpssjYiZPSQi/itjYkWgWLI4
# DATA K2usomRxHC2SOT8TZXygPSFzaTFOhtkumLyPkYeyjFWOEWUvPAS8cZeSP42xwSQhqwx7tmSgz6sLvTPMlinAYCELjFImsz+/ot32
# DATA aYT2wyk65ZIRHRwhAcKxwqQ6XRmycCK4rwGc1Zpn5mh4jobnaHg3SMPbZfTYaa6yq7F7q3b7Vcz267DaHRXPUfEcFc9R8RwVz1Hx
# DATA HBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8RwVz1HxHBXPUfEcFc9R8Z4bKl6rHfQbnatS8UajXjR8gah4
# DATA 5ZXnncB4Bepbo2dR4xr1hqG++Z1OkRs3GnR7Km8ogjGNrCaIRh5Es1nPyyYQ2p4cngp6hfA6zWDQGKwUVNDyvSAIxkGnfuw3m59X
# DATA 217Pr/qNltcL6E+92sWXai9YU3KraL5WQKG16uNm+/NOx+v41SbVA795AXXOBLaCiQs6azOga5H7KPJW5Wy08gxoFN77reYgaDfq
# DATA K1FutOue3/I/r1Jam1Rbqh1/2mpS3D+vBj195coJ8IMrgO64VWjQnTQwC3TXaTYazeYOoLvhqF0E3YXD3qCZg+467Vav3TKgu2Fn
# DATA UO9boLuO3/CbnVsA3aFJVbfbGx4PL9atZT7c9yLqBeKwIgGXFvNWUHENXjDLl8uKQSu7ZcVJpXNoxRFZ8vfbYa3zwF9qUPXY91Zn
# DATA w0k9o5bA1ibduFVXI2nM8iJCToUt6Lr1WwXKRLtVzNranDEDn179qm+jwe1QC27KFHFoN4d2c2g3h3ZzaDeHdnNoN4d2c2g3h3Zz
# DATA aDeHdnvF0G42zE2SzQe27gpIbYhTbq/tf0e+8ZIjY7kU8ixZhBO5Hy3q9Q/CxbjGM8k9vrj/OuUAjqPSe5QTbQ6NmeWcb98rvOOO
# DATA fKMfM+5FFsm72I6359uhfCqHyaxAyu8sBcPPrhw50wQxmQKaIx3uELU7RL3uEHXpmI87Tu2OU1/2OPUW4dubOmYtrYDtYOi1yyqr
# DATA OWb9DIU8boO6MFTHs1XNwFdv72hfSdrqZjdjB0YuAK+eyvsm9T1nFhRZDNOYBehaCtvAvn9ZdMIWC16LqvmbhW9lPIUUsxnWUAw4
# DATA VC35f0F09fMmvuaCibDfXhfhrhXhYPf48qAKShvHg6NJVy6IpHoo1+1V3wsciJUY+lYMu3YEi9HbyHt4S7WoyIgGvbi4h7fYyuNh
# DATA jAFemJzoA8nvjaCyiT6Ej+FnPNCh7WVklswr7NOkVjqB139y6kFJE5UsBi9PjCLx1gudS2odnxunZqhCHFIQFCDMnLEOcJDA6FEh
# DATA 6ePgzJ/gmhxlC6y785SKJZimbBFbIgA4Dc4KjLyMOsRJMk/Wbg5tMQCYbOj9smQa6Y7ofZq9HGOGNGYABrfvAXYHqwQh2nlfczGg
# DATA 4eU5WOwgsc6S3W7JOrv1JbdbLwuFfebyQLxgbi0Erxp9k4IkIFN/MhbdVvyDPh8jhSmylaH6zFWFXhAFjpvApq4oIF03OXWNmtR6
# DATA eOpuSoil+oestmkKLCL9Zoq0qmGdVdtzBWne06MnQstM4FSan8q2WIR51vC0IOkSetgosZwq+wwVjD5kkTKUEJjUpKKBotDJ7/IN
# DATA xigpS3BznD9msVeJckRZrGP8npmoxTwHpKiKntEiTiuszM6x0arsBQtNK97b+AA2SBEUWQE4grEl2h9hYW57rB8AuqJizduUoqGO
# DATA +Dta4mpIs1vEhpLAuVfhKV/FO8VmWVF1Qo+xSI4iqFjVPMuoTlhZdOoxqEBRXzZFV79wNcavkICN3Sc5S9NZmusszcI45TymzmN6
# DATA kYH67IUpJQaZUlZMk2TKKnXcIHJ5yslEmspakcSaqucVcVZUZDCC7hyaEdanmQrGnhVPVu9Uu+JlxMtRwN5lK0GpO0qbVMuNHCZ6
# DATA vjljN+ECDifYwCAC2Q4KtgsUTCwu27TadKfxczPdRX/ZfL9W6eRcVZ83361lPIvmx/OPEcvz75IcF//Ab29GuejCEJTLD2YRdSZz
# DATA di1WcWRRW4ZY3/Bb3pG9khE063RBuRE/jRSBjKYg2Co3Oa2Q3Y69v32qFyN8XWC8RMjYQ5JhzUNOdWTcQ8DYOgmzsWipagudLk0m
# DATA 2XVwcG4l/z45STj/hjROzYu516gXc6/ZtXLvAS/UINnc16pMgmIpgM4LlqMUaUy5S/zCkwj4ImzW9dQhXBEqvYbcKrTBy2dYa3OG
# DATA WQ1a8ux71KdS7N5NeSo7lwlMnm9BqdY1Oi0r3xYwpXiZjA2neLZcYMiBaOmkOLHiEYNhPVTzaHalKHhmEnaMHY2T5yDv2pfIu7dQ
# DATA BVKRlcjXBwvZV6p2jaBeyr4KT6XZRD2SoshonipKqSD2SWvEfvRhGp5gK69eGmC92Xxp4GnyzO7DL5llH2zOr3w0UAi/5GGorWud
# DATA Se8yp0K4EUD3Cb3wmGwOY6aThfuQGt5EoZ2GrDo8TYZM8vPGWAf2PhahYGZa4YpZPjGrMhkN9JTrrMmLFn0d2WYPZpeuacHmjMsH
# DATA Rsk44xgoGmg6Dx/gqvK6zDy/SzVsqPMq9Bpt3jNEFRXbAtmFQNMl5YgR240x8lzXEu9oGSu+F3NjlfeGzUbecv68IrxeFodEjvEa
# DATA xQtIzNocr//37KvzX579+exLMLa+8s7+cPb7s6/O/sfZl4ze+nIV2PVf6KffnX0Dxtb5v8ctniC5zv5y9kf66evzX5z/poJwKEwK
# DATA 6/9n7+2a3DjOfM+51qcoe8LR3SYAovAOUk0tRVEvM5LMQ9LWnrW0igJQaJQIoKAqoJttWRGyNXNmJsZxHLE7ERsxcXYnNs7F3uyF
# DATA xh4dy7Kludgv0P0V5pPs83+ezKwsvDX6lU0yZZMEClVZ+Z5PPpn5/31Hv/3RO/47/FSkO76h33/Nb/rm6Dt689fHXzAeDMguRQD7
# DATA NX39IwVIPzlm1/PgUsmgfugyRzYPSPqQNIIPlJqkxgUms+6U1e+lQ6EMC6cCX9zH9C8aiQtS2i1cqH2cPgcHAAol/BQ4jLwRlbd7
# DATA dpVGfhwM12K87mNlvBccmpg6jpfta1EdxFWDvJaUyuWRvFQtzJaMHqlqOYwonsnh/P1SG/XN7+Qq6UXCvOAyVDERLXzZmR/qeDmg
# DATA 12ZFd+FMr0dhBjrIWBAJIKm6yzJUDi45L0Vvg71AIiPMUAVzihien0N8LXlvRz09O6beTabX4pxSKV0ge51cGVfbM4ut7FmhvU5O
# DATA hUN7OXPg4s0BTfs6mxXwUqy2XJUFcBkGwEbj/ymH/6sZ/aViLuSCBf26Zo3qMjhgC8kH1BRrQylz3tenrMA1EKpXnIT5dL4zVVsj
# DATA eAsEi4REQWLepIPilMuCE4pTuQ42IoM9Zl8v/EHYgJPC9RYmwbCgLDka0KLeDMUX9rgYYawlVEN4DbmXYZ44wtoUMDtGYB5QoOLy
# DATA gHOK2jhcM9G4SFnMIHaPrItpNA61o4qXzxA6lqFhthTEZqEXix1iQFCOEuYoYY4SdnmUsA2HnI3mQJuazlc7DTjLLOAiJgGOFOZI
# DATA YY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khhjhTmSGGOFOZIYY4U5khh14YUVutUe/zz
# DATA mUhhzX6933mOSGELS88bocLsfPHrXtVvDeqN9hxtqkG9YytcRpuqtiSHuIykDGqsSCmkLN/PKfXMl13Ftwuvkct/885c6PW2f4mh
# DATA txtZ4LV2LnBJVRa4X23YELBc4O1+q9PpzwfeqLcvPPQc6K0mLDaBlPmNDPRWb+UCCOtB0KouNAt63PP91n6tPqy0PL95AoFsdZ1o
# DATA ngFAxo1NA8ik3eYAZPWg3dgAQJa7AgBZvdftlzMAWaNbD1tlAyDr9ruVXmgByOq1brt96QAy3UDXwqdKfl1TyHL3m9FRLxDUN6GN
# DATA 5YPQvLGsH9c5teDItB7tYFFmyTObLguUGsoCqdiOh0ppyZqwzwZR7s05j4JYBniO5y/Gm+TXyU6ASbXEI1kxHknJlPllliULffWF
# DATA F1Ru67kW9d5+ZpfMRb/F9twyLlq73c7T0LDKvJpSliu3wlxZrLF28jfO+R6M+9BhyByGzGHIHIbMYcgchsxhyByGzGHIHIbMYcgc
# DATA huwlw5ChLlAovWFYCHmZqLdbLrDTnT9NyOwO092ff1SAQ3U/3GULtoCO9gF+2kWVvG0qNJ8ug3WUbO98FvW35aGdz3TQ1EJhggTj
# DATA blgak4W6U1Svum0Hf5tVnfXBjW2J3s5tdAUfbj3OjrH1BCf2uTXHwT5C/X4pRRz7WPNepJ+eoqSykgdNjJNt1VtBn1jSTwkY927s
# DATA TtTu/fTHMOxuU/oQ+Kv0285n/PTu5DafyaA40Y8/4GsUj6WpySXYZP1tk+G3pdZhQs+NPqthlOdvKn1nynuFhNMnf4zys/cYh6Ty
# DATA 5y8Tij4TPCg/oliyT2z525+vfh2T3rphNNzepqQWkeadm2zaAvKmsoRiQkk29YIaEqe+xG7cnc+yCmNdlrjb91HG2Vy8rAapWCJX
# DATA JYfUWLDzWZZhKDoUZ0TZGL2qyHks6YZ0Rjdu6JtLkxmZJp+pmN+SO3HKju4rcERoYv0BTt39xxf/pM40ApsX3fB3qIuhSCwEX/R3
# DATA 1oSN45F22A9xXJKXPxZD/zyrC5+rOsKTSd0mF6uyeuB2rvbflnq2ixmsrnrWDYVKvZxvUclsLFLCQujj6sCtjC68ts7Azdq8eirB
# DATA GdKTnuLytbsLq+ZnOTDXz6xrEg+hspq1B5UoREUnycwBl0SLz6BEQ5oPmT5V10DzmIwVO7lIU7AH0Zimi8sCxUoaPRTOZZJjxjid
# DATA iTPqTDh9iRdfX+K0JJnroDvBKys5f/16nMx7OAQPIgfEV/XB6WAPr5rGozihmdlapsx1FK14fo5wXwZpZlFj46JRM8tETM7ImvFy
# DATA S0RSpXmF7Y5f1tLAgtk0cmL0MnULBDylnmQiH7bQ+xOyygriehIte0TeWN6ymhdPMIsEXE9YD4NZMmWpr0i9d0Ij/1j0E2Il9WFE
# DATA 7NcIfZykPPoCHdHPNRxnQjkTakMTaq5/daJdTrTLGn5XGl/XQczr9VkEplZetspIeb0lulB2U8LIMwljNLSDQZwboQQhoAewkncX
# DATA IjYoOtbUCWQurOBj4RNqjsEw6kPxBqLbcD6IhNQ4DHsaM3ZafoqJqAI+KDltSKsXlihpOXjKJvCUUSxFx3r36vM6IErCbjSRwJfP
# DATA q+/Gbh/hZt/jT6vv1OaO4gvx5+cBnWLn3ilV8lswHFfr5GdlkWNZsFdPi+PzrCgb2TB+JfFsb5A1hk8Y9s4SHhqXNBuT8chaVNmG
# DATA abTn/Thibasum4eePkEPq3HGYnMTlu+FsUlx2AunF0EZOEf+1U+Xf2+E6ROPne0WWgDauAruZNLLknHiCk+ZZ2ibDgfB8AnllZYP
# DATA 5PBw22wITDejGr1wzGXA4m04BeH1ZokW16VB6mKYFlkzPC2cobI+37JWLfn2Oo3xsu+PmTqzyNQ+ZVtRnQvDlUKGWD0ag2UhecnS
# DATA dLKYkCp6V5hOS95fMxAj7A7G0aez0CgoUiWlCR1YCdMBph2DgGsi8nWqKu4F5GbWTZ02L0+og7rXk5z8gOoOqyBqqWaDITWZRGnk
# DATA KsQWqkKNGiQ8WbjdJ5CCnDNlVe4FLLuokH/DUE0yOduVhpwR9e7nh+Fn1YIbp2vBrwdDtiPUVCG0WTQwDjhD0tkEEzBKYJB0DtXc
# DATA oCs6i7LTueTxSg1yl+XIE8V2o1zrhyFEFDHVIosiTCdhN2IirKhfJoesZ2gm4ePw4CJy0B77TlsBy+uzMBtKFWwFlSsxFzUFl6Zd
# DATA I+7a0NkrUo+ZhnUDUHkoow7IwIapjh0U3oAsQtQvZBmrgLLwIVVq6EDuY6uY2mNzbaEqL5BrIwvC+TWcX2NDv0a+pjm3hnNrnHFN
# DATA aKUL5NI0ylWVzdFfYYpTNTfejWfOyljn3WAm40qOPW/05mUO7P5WJxf1NTPp5V0N9shpruhZL+dSdj4SO0PoW9zvi2kQ9MQuyDkk
# DATA eFcL/cw2kul1ttX2lB3lF9EtfMwb+vEKiZR62vSM+ruZ51fl+CaGgYSMezJe+MwdLo6Cp3JHWc7JhRM+mrfad8KbZDglVpluHFX1
# DATA tImq/m6iWjkxqn5r46jKth9Elj+dFDd9exY7c8XEr7Yser4Vvcqa2KlVQePPknMBPP0Db+8m71MckYktN7L5kYzuvCrSClkW4liI
# DATA XQezS7k6N6HBfSrHcW9KEFlFNr4Zq32YSyscOGIS0WSwZ5naOYX//0y2aVdPUGli3scoaUA6MmU4CGh4B2xnQo+SgYYZmKICZbNY
# DATA DaRUdEI12RJKqtn7ayEtMSTHwyLDLHnHFr2lBx5mLDRReFEKXi/6xS8iDCnsXhnPUgjyp4dk+8ajNPOi2jEbhMPJCQvHc6WaLR7b
# DATA ftVsGVjyX/Zs0eMP8CEr8TMFJlu5pFGGU6v6iA3LJfZyWOUW63CWkE1MJp1NO/xvDC/8GrTBPIPw+Df4e5F2+M9HXzGP8E9H3x/9
# DATA 3jv+m+Mvj747+vb4v9CT39MnxS1kxiGIhRI4h+wxEPErYBSPv6Abfnf8D/TQt7jt+6N/o3D0k78/+h64xG8Yg0hBOubh8zDDMNUr
# DATA m1hwhQfxBDlKzxSUv5I7HI3EYOEkQ3eWCJNF9IBKUWgEMKwMwYN6Um30TKKwS7PxdXDDh3obAw0AjFZzaENrMqEL7Krhhgulcnlo
# DATA Q1VH9G3gbGjiDv+ycD+2r1gd7qO4r/a0XDjakCOQAxtGKVd2hzXcrNguHGt4/+lkiF4m0M6QUdybDQOQ1+Mpa/aUvA/Q93Pfle3z
# DATA 4sUvbIynZ83+J4rDbMQ9ZSrboOBCiaeBXssKxoKOWQAanlwFV1st8y3rWeEMT06Dwxm6kf4cI73mFp5lgH85PIVXNrhf/Ni+0dB+
# DATA ypH9agZ2qZZzeWAxC59Vy7kMOOFcKrECABKQ4vxFXSux+pzjfIICcWkqqBxoa3oTdYri4c3Xsq1YS3TDShqzV3Q+3zYkEhovaxa7
# DATA dBp3ecWRx2ONimN+HNeSHs21x6mJfjhLYi8YMf6Nh/yQzIaoG2FpPGcT5CyA8CkOFiPwXghvlNpRrdYKyXqg4nwvDFJEiG277hSu
# DATA GDES2asjlDpZW1dF3ZkdSv1ytEJHK3S0wsuiFW441Gw0tdnUMr5KG/8sJv5FWPiOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXo
# DATA WIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiFjlXoWIWOVehYhY5V6FiF14ZVWPdrtXr3jKzCsNf3w+ZzxCqcW3g+Namw7ntVv7xf
# DATA bLc/9ZvFatNr1unvQbVe+bTW9ipeo+JVm/vtdi6Xun6n2u3PY+worMZSjF1tgWwoJ/0E4NfOA/zqVX+O4FdrZWUtx9Yygl/YCoPu
# DATA IjjR4gO26rngK9V2Pvh2dWXoJpm50Gvl+prQ62cK3S6Rlu/Vas39WntEXWux1t6vtTfOaX8RRtj0vbrfHDTq9blQuvVup9NdiqI8
# DATA PXZQ2o3GDkoTtLCDjV691eydiB0M+p1+I4cd7NHfvYqFHew16s26wQ52ut1ap2ZhByv1Wqt66dhBs00Nwv97G83X13D7xL71Fuwi
# DATA bY7Pvc0MlGrq9VZI3U0UFCR+SwGGdbUSV1mg9WFhceEFc25322jUBZKfd5O55/mwA7yG/LHDZOt04xyqa9MJmSJGbj6oO8G8oWJh
# DATA A/ORtTcX6BFdLXuVl3l7ZTEln7QKfJ/8l/pjz7jXEwfnsrUwnydrzJa1SWZ7wgEHHXDQAQcdcNABBx1w0AEHHXDQAQcdcNABBx1w
# DATA 8CUDDtp8N0m2eDGElMZHxRH9nR+3yjcq5QLNLNVPB1yEOzJl05iv+3JIhg+6oZHd4F/BpeuOEHDo/X//h9cu41svDCelD+m/MWhr
# DATA FO6d3fJrH259wFrqfI6OF2oQCP0oQZR4ykMRlrDM4RvExesc4l6m4wWdFCHumKfwid/1jn2UTVLnhekUfuTwlvcfv/5/EZmFtG9X
# DATA K+UbcpXFPdE1IEiNMnMIMXe2+6Sz3e5M94t+pvu0pLDrcNZ7zsW2HhP2LpqGeaLkvYdqb2u7LIWDPdPT4c/P0cjLoIDNH2a/aAbY
# DATA oiTAWQlgeX+tPqv/LlO7pCLIa/qh0bV5A67HwOvF9EN6wGe0H8AJiarFUkCDIEpK3qNoyu4nLfguFVCEy2cTOZ6sCjd3fD/IpIwm
# DATA EG2M+3wWORPNmVO4WSjnJyFM5cDI7cAmunqlm2d0CtZqQc4YcsbQvDG00KM60RsnenOSGXU9xHAeSH1lokUvNviLT+KOUcR5aLQb
# DATA qBlGe2NF/lIaagofmdCw0IW4RR83i5JEGgC/CveoxuPwhnyW7xAdGrghh7Z2yxLNlI3BX4+hOgP/WKZkY/Ng2Hchqh0O97UZ7ouS
# DATA An0SlfQpt5rVsC92O4osNH9cfS9vz+We5TF/eh7gXVZenJK78mgNP0nnqhBX7qFVUOmKbSXAlccHsYg1xTMIxgSQYxHIyggtRUsk
# DATA ooYH7IUSWSYxD2lc24cX+ReQZ0lGefUiUSki2y/OxrsAgjBUOwLRqO+zoazPnEqjUbOD5cLOiwLQZuFNbJIsgSbHtJQDxgYsKHPG
# DATA 0AOWIPT5+FdnLrmHG5fcQzlgLla6Lrp3YYugIwyYDUDFsafUv1MmfYUTVsdRLKE8OgzFx5I+ovZNRSCT1LuazwiPodoXxb3pMJwq
# DATA sECi4pJO4un5iyyXsqsrs6w3OWWZ/WQdrUz1S1JmP4EAEfKxE1OEbEAUSxPpdRQtaLYnjCzKXerEcTHukzVieFr98EA0p/TgNhVJ
# DATA eNwpiztc0gdMf2Pmiml0XPqdWXp4/tLKp+k5KK73Ny6u9wOA23kxg/r6jEeVDkRL3zQG6vX24A9/Eh6Ktd8JoKDlDeKRNCxMDsYc
# DATA GmvUjT0qqAS0MKBywKtiB3w/eir4OIYmZIU5L/x2/kLLp+zKCi0bhU9ZZo9Xl5kez1WvKMqBuJaVl/gjsA8fwwA1oVRYgUNxxLA8
# DATA cleNE+yN8+5y+fYZ30WdEETIMO6J5YljU95kxofnWDxhDLTLBfR7Wdyvf4lUNi2R90OlXIfhY6p+UoRLOR8U6gFGmpNYGyLUF3t8
# DATA vAst4FAECQUMqFoN9288s0YAMLt5KItSbaSgdEX/7gLazGJCzlRMV0uYOxfG5GXws1lBOEebc7TNO9rsKuV8bM7HdsbFxpU+uUsS
# DATA nJYpucz0MAKicsPGNC62Zwg1uCTyXM6TpfeewN7nTdZYfmrxvhmeCavfTwCdZaGY7sq6lFHjTkKdNTbksB1ob5kBd/G8QO3a2+6O
# DATA TgTcSQAZ4E59twB3S7FxvlzW4LjyxpA72c0DdyE+CGNMKMhQKea8mnMgqgcy76EOYcFn1ywz9gvb2r0DLGTy/qJmebWXz/f5kcfh
# DATA U/REPesp+mXNYzV+7G26+9B+plZe4yZciajTpil205KlNn1+IXW26+5gQKF4n5DlOQ4PS7bks9J1lk4ADqGD2PO5pQWJgsXpDWsT
# DATA miYp0x2rztRZUJwwveKBm4I27nhxaHDfIh575e7X6tr8YrXtzGPAJRVYtVLmeme1cOqjZhp+qfbkdvM1FXrTSoadQtEq7AWy8J9K
# DATA 1zemOA5lqsiq2ZNZAtC7LGzHKeunWgLZG0DkXhDjOUPIUS8SdpOgP7UQcu/pa8Xjvz36/vhXx78GRO7o94vouH9Zin+jL1/TU18e
# DATA f3H8K1z26J+v6eLv+O+vAI6jK98efXX8dwYJ983R10ohHQpfE2in0pDtMHHX3tRnyzzwTJ3x/irYD7z7vUjOYonovdpXwrPffhKF
# DATA 4x51IPztIE6GPWP9w/M9m4jvFK4EcZ0ND5muG8OlLRRRdhpkCxSq58FT4VNqaL21CLnXIaDBWhMe/y08CceRy2YEplO4ao7c8qK5
# DATA PJjcgKLD5IIMTs31VV8/CSZ3LxBJ8MsAyvHmK7Id6V8aE8R1hdEcDcYB5TYrugsHykmeBWzmjNG5ybzKTKe0YaMmUyPpoMhy0RWF
# DATA F/hoeEO/y9b23iygRjENqW97I0qfFGD90NP3HvzUSyehImXg+DulTanCzNgGgmtxugFtbnkdXW3iLG2D1wU7tzwxDj3nrIdLsh40
# DATA lu7MRsNL4UK8OoPhkuyFjcyFU1oLV2csSCVdlhnGULieDe0yKHZWNgA0h0XiXjgBh4pMGTNQmxzi2fyKbOnGo9EM3TUW8N7BDKLL
# DATA DguWFEkpX7qhPeInITsoxPuHDEvVZnsa6anI+Ho/SvgUbZpuTLgDSCtVvlkNE6MM2SeLMBE/h/q1T3PliA848I6g9+JPaETzOHld
# DATA ysC4Py15D3W85YCCgoXNO4EX7BY5K6ARZEbTgklmyA/o4kA6eECZHHXFe8xpH4u7hvdyhmPm6OCEPFoXQGSqSlCuOuadY9455t0l
# DATA Mu82HL3OdLBrnVl+5TONi/ConnWe4QB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgOgOcAeA6A5wB4DoDnAHgO
# DATA gOcAeA6A5wB4DoDnAHgOgHdtAHgVv9qrVs4OwKs+VwC8ZSvQG1HwLF5cJcPRyWm0LN+bcwql9VYuu2r1drMezpHVKhUqgNoaspr1
# DATA 6vaZX92qdCqN6tlfXWmc+dXVVrNT65391dXqmV/dqLSrtebZX10rP7OyrjWfWVnXa8+srBv+MyvrXLtut64yw3Pt+nSvPm+G59r1
# DATA 6V593gzPtevTvfrcjav8zMo6166vtqxz7fpqyzrXrq+2rO12Xak3rjLD7XZ9ylefN8Ptdn3KV583w+12fcpXn7txlZ9ZWdvt+orL
# DATA 2m7XV1zWdru+4rK223XVr12pqdA+86vPm+F2uz7lq8+b4Xa7PuWrz924ys+srO12fcVlbbfrKy5ru11fSVnbrodK2as2K4N6o7zf
# DATA rL9NX/NOh2anUa91lz5WqzX5sWpj8bEaHB3N05hjagJiweX9Ri5Iv1WtVhZjUi/XvUq9PqiUR9W6Vx5UynO50amH9U5zKZK9dSaa
# DATA ejWjqYs/x6Kpt8pBWG/kaep+u+pX6jma+hxfHTT1Ttju9jOaer3SaNQ6hqYetDv9oJzR1Gt+vVspXzpNnZ3BxQ5v0jeeTlls11j0
# DATA zNvaEoe1/cw8EN0sxS1bdtMbNZq8QRPbM5mJvrjbsQE/q7yGD4Jtti2jYW3LWAl0t0Jdz1qX4lJOy7pZdtE1go8lDIJefHCrTT/i
# DATA T9lTpfh5iV41ggtsxRJsZSG49XmYBeipraZ6/5osW5lfJ0t2H6i1Xl3DzDKA2guaeboLcycK8svb5dWwdbuk1rjDl9U1dnKzX91B
# DATA 1R1U3UHVHVTdQdUdVN1B1R1U3UHVHVTdQdUdVP0lg6pnFqPSbtjeMfYdpdp7KNofmfDHbSFWcZfNtvLwkHHlIipSHMW9cFfQFXRR
# DATA ttmiUWfXRGSiCBtkt1KvN+p8FbM8kU1LdzUbnafGCnGufkOj1IB0RAwuiCmE2XZbEng0UrCR7JeGvCCe9hAyFya+oJpz2yilNFSH
# DATA 2+VCo7YD4wgHVbZv/vxD9d+t3b/8Af5NOJiPbu4VqFwtTjuXrbcIp4eqwO5n+8E4Gg6DW5XCZDijaX96q1qAZNyt+uc/56jwNNbE
# DATA 5SONp38029sLUxkXWYDMe3j3vVsGG98No+E23nBjPnt+XPJbTJN/K3pdoPWvs/xPpsM7F4oEIAI4NMlHEJofP4kEKu+XKjpIdM6K
# DATA JYJRQQQvoKknQof8QlVnoIk3hTzflMxlXYNESQiSLQpIz5mQacjS1dfWmVOcwVF/hSX7mZloQCJtTp6Wns4q+c5tjCxwXM1p5EDs
# DATA QyUASi625A3HWAaCHxbyAh1Op87p1J1Gp25OzMUp1jnFuiWaP6tZFtdFyc6bJGinrKGVj5ORsrubl3Tbm0EaF8JMq7TbFNhiDN5s
# DATA 1I1U0JjfsRqrFqtiGu28JF0erbUgR2fuG1TuPMDQRF2Ljrh4w7Xc1M9k3FaKaRn5CjZwzIR6YACBusEyTpFV9KcsUC/BpdDy9WTM
# DATA 11Pd2xCLhdaUUpsDYsuznmScJ5StKM4htPEpKRGMa80h5CN/cZ+jEz4FRE1kvdBTmYdppFql1MfpfkPZRSy3lyndqqFRp/+RMaQ8
# DATA bUhBsQ54H1EqpvmwUE9UDkWsY1HyfoaRc+GR7mAG3WKtP6bMlZLHk4bcQCt4YAGgiqe2kKMKZxYFGZdQ6JOeG30sY1YiRJhBxfQq
# DATA c5YgXZcjd1UXLzmienVuLCY3pvFEsQ24rsQJq8lB/SydTTBCY8sx9JyprnXDntX/T4MnAleAVcj2DCZfk0NVqHpwCQ6Cw8yikgFI
# DATA Yg9ftfc4ZEemjhuDXQPLFGMQsT3kcN2KpuuSze/H2z6JKdM6GAwDrnM0b9AJfxceFM+y7bUqINOg8nqBQkNl0S6KEha2JlxyLCUX
# DATA 9KgLjwzZRgnK6QSIDJ2GP+kJRiYop1k3DOgMslZmTDWm2mlTTmUD9TnD+JC9vvOQNVEGe/EFzrJRxxmozkA9jYHqzNGXxxxdaWZe
# DATA c2Fle4F/EWE2zNmp0mLo7+mAByTYKspCzR5hvR6Fwrqu8svPl5roSUAHayuH4OZ4i8ydV6mDnm+p+jhabpNXqzy3yUsdNQuG/G1Z
# DATA e1k8JiatvxvDLSVvPBx3dXSU+tKdnyycMmMPPtk8K4S8rWf5C6drDgKmN9JorezXlc040MrTnD/aGGODbbl4s7LKtDww8zpmE8uW
# DATA NAxOGuxhj+rpgsF85Q3MvDlqOfjm8BXzdeH1WYSav6i3LZVigdh1IuFjrF5coIgkIZkuQYesbgX4mGvvOP0qTUETgAfVO49GAvym
# DATA 3DQ0ZG5urOUbKCLyfn7WwjLgoL5PwngypBb6Aa97IC+y+QermSniosgk53TC84bjNEDF1aA3Yy3OI6U5yqr0dHTV5M8Y+5g96PJU
# DATA zDSZYWAnhMw4GUuCWYrqqlRpr4nYg4SMyO50fcTu8XqDl8LiP9TRUxdlJs0WuBegKnEeIScPElbNjg/GNGWjn6IR5NB1ZV0am3sy
# DATA 2VuMzUsoUuy4yc6KP6sVP1/lnJ/Z+ZnPbcCvnC5cnp/Z8MTneRwGq3YtMV9XwV/WK7/0w/2nE9m3w6vgZMqE8SzVvtYTeMZZMKbf
# DATA sy4ZgG/rJACzvzHQ2Bj9H3A3iIjlAcb6hoyxbKYJ81xhtcqO35TjfjWDWK3DyzSPP66+F6XOZhv77dcwihdTxmvpJnX4xogJZZhv
# DATA vxW9fiJi2gomnwf6ooln7aRiqZ+CM82r/gr6R1GVC9gTQu2VMmF9pM3jFnZaX8l40ydFt7ppbHkjR9aBjahjoL5jLo7YnWOjxqe9
# DATA PGdcvpvY3fVSspj0Mo0d1Q2Y1Pc1Kpk7iCTkNQvtmX5+AdVmrUA64GEwG9N8CAsC6TTPqDbp7wFOw2YXrxFYlCH07AnIzEBISy9T
# DATA 8u7i8n5E9o69SMaWUPi0q1YzPFmPUEcd+oqaiQ0egQBsDlNsWONZB8/YxIjitQplKCVBpOhNYEkHE+mp58ozc6Co3jHbRJLLWMs9
# DATA YpA8i1zkrNglj+ZwTEs4TLzCNg9iYqZVLw4FH6Vmfh44UQeoZJQZjAztThXex4xCJ3OyX7RZkwXMnqVRF16eKLaQ2Uf/7fjLoz8c
# DATA /yOo1kd/Ov7N0XdHXx3/1gM7m374t6Nvjn+7SM/+p6Pvj/5M9/390XfHv6W7j/5AD/873fur498UPPr0PT35+6Pvj38NijaCFpL2
# DATA r+jvb46+YY72F/TIv9ItIGn/0aO7wOv+DQX7DQX7FZ4++h1F64/8JAXxO/r7O2C5j79wdO3rPyGkTiwehUWQ5QSRpblT3Fd1qZkC
# DATA hDfkZWBeLX+gRohA27QFQYKxc4rMuMkwVLwwRbui3i/RUHtmg2VG61qK9kM8RH1Q6NDZufle1j1cNTzbKpHLI2arWpVaMz2+wBUz
# DATA nb+7EwZZd/06feHK2AlprL9IVDaFy+zqSI9kamvFwqTuJWVlb1BoF07KvjeIoVMfAGJOY+pY26+Uwex2UkRJ7k2o3Bb2gIvPlywW
# DATA 6qT2w+FtxHXA26TIvkttL1WQSm+oN6ecpv6ttmCy1vSs2NcnRt5hr92wfs5hXeOtTzeavxye2yscyS9yIN9oHD/VMH4lo7jURJP0
# DATA bLfvM20qlwGoNmmU7aGrksedt/L4cDkXZCclpWGPpTKC6UDS0MdGyIEs2crqM03PAyHTJoPD6WCUFZi1FzLQuaGQxRiKNyFSvx97
# DATA JroC3tXMZY7NOPak1SyH85a8u/wjC3SnQiZmRWdZwlK9KgJKp/GErK2BouBOgw4yTA7YifWQpcoAsim/ulEq+hQ6S7twRji+tONL
# DATA O770JfKlNxpSNpqvbGj4Xo3tfhbT/QIsdweSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBpB5J2IGkHknYgaQeSdiBp
# DATA B5J2IGkHknYgaQeSdiBpB5J2IOlrA5KuVapBvX5GkHS/2i/3688RSNqsOG9Ej7bzAy7Wen3QKFf2q9Xy2/T9F/P5GNbbS/BWLc9v
# DATA 1Qb1WmO/BbxVK/9Y1+81e/78YyO/Vvcq9Gi1XPSbXqVKH7xqq1ireVX6P/3WLLa8WtUDPMsvVlt8rYLb61617VV93I3LZa/t1VrF
# DATA im+/lXdC5tlW1V49aJSXsa2W1I064tPc9yvzgLZOo+N3ustCqS3A+GxKWjWPDJZwLYBXI6u+1TzJPAzqzc5CDCuVxvljWPGrWQzr
# DATA 1QuOYbt9ATFsNbIYNhsXG8Nqs3L+GFa5SVxSKdeokZw7hrVq5fJKue63zh/Derl+eaVcb/sXEMNm64JL+TQgPRmENEhPxjMLpNeu
# DATA 1f1qOw/Sm8fm8ZVgHqTX77XDegbSawT1sNkyIL1us9OjOboB6bXJOq62Lh2kx9s/i+us+1J1jk/3ufXQIosu5xLyW/lZj84EtrHg
# DATA sqW8x6bH7WKlF+7t5EKeI/S9FdK4HgUFifu887vKrm9Z8mY43/z6vQqZJ2ubrqmVtPnO/tyqlXQE4+mNRznL3TgWcMRA+8KxMax4
# DATA yiWg2jIHNPvhrPCUF2wRz6dqU740UBiWV6KJ5ZXl26EWXlFCrMlmtWb5ZKLqxmCXMFnF9W57NXQvK+GCXSZrZhGLtU0l16pGytm9
# DATA vnB4KoBav3IalRXU6eajDgLoIIAOAugggA4C6CCADgLoIIAOAugggA4C6CCALxkEEHVBTRR32TotBDj0WYCEb1JgGbbybckPPh22
# DATA K7Ul6v2vu/ixiNpymwMR8YhdNbyprxS3n5cLlUKt0KA+MurP95Dqtp0d/bi5+za/zlTE7XEhAv9trLu9XfWE1evt3B6vzSUA5PSI
# DATA lcVPvUdGyae7d57qN0hPRleUnftUdWf0H+h19hxjgqNj2zuf5XLyNh8C1rYiZ+jOXKrGu3coQXz8EsYoz9vR/PgcHJJQkpOfCvNH
# DATA QXOvpCB4O2zO5aehH26p837oKLJauUujLkvIyiljqo/CwHsoh46RhAl1sIy5MwmbssUL5N4P1Nt3xPJfXjYnpGQa7+0NcykpRNTO
# DATA UYskSRzoz/H9I1MECqgY73Kt1LZ/2oXOI5K7U9jL/fQWTSKoYsc0ZIWUMePuoRQav4beVn7Nb5VvVavl23ulPboXxuLPcMNdNuq3
# DATA cWqhoAKUbei4vKPvDp9O4jEE24Lhw2A0eRznny37i8/eKJUbiBAlZExFtL2HwPQXuRtKetGYVzZxJ3ugtuVTPNleFmKTikkK8IFk
# DATA JgsmAu64jQ83fGY2xn2vxUXKide//Kh1m+virjWRQUkXqmWswAkAEm6UmOva52pOwsr4GsGoq8NnWd2/rarG57oN8BR4iu1GXIR3
# DATA 7+0eRGOaWJX4VDnXy6fTX/5SXTwIO0+iqf2T9Bb3dqYDGqe9+0nCtVuOpFvjNNLHWST14Je/xHzw7j2KUHAQRDT74+xDPz3COLmk
# DATA Mp+yFcUTqxFJ/ygN5fbnPNu380TKSOKcNy8Wj6+L6JEo8ED6UE5xd0IvpGmabpvU75ip7JKujs/HRUOa1uU6PRSZeUyGvB0rlhSo
# DATA KoUlQWKNnx4xQVnPcda+Jq1eghGfmjlU67RsnJbNMi2b/EFrJ2rjRG02FbVZKUB+WWI397HuwqMr1CbGoS3booVvnp2A2lWojIsp
# DATA QJcf44O3jeJIb46i8WwanqRjrZ81nZO5YCSXlWr4vCS07A1RmtCVdRLW+pgvRZuP60Ix/hBdFud3zMIZVDq8gDaQlSYuTgpA7s9n
# DATA jFlPsnLC/MhmKS9ZS97wFKjMd+YzQntwsqwwt2ZJ5wf9OXXr9e/yN3+Xn89mPFg51bsqm7+rknsXP1g91buqm7+rmnsXP1g71btq
# DATA m7+rtiC1fqd+qnfVN39XPfcufrBxqnc1Nn9XI/cufrB5qnc1N39Xc0H//U7LvEvrq5g2vFJd3Z6+vgBi6nqoEKSLViKyRhvq+54I
# DATA WglHZ2gqJx2YjJCYPQCbzJP0EaSWklyXJyH4Ba9a8Oo8HDVB0QrHLKTqYQcBBy1A4ZEhgVkRo4Fquf/UQ//KMANL9st42zNVKRqm
# DATA MG/QimAYBBGmWI2n1wPbQMr8+RcTctBWN3VaP3VyM6UXc6Z0WhDrM5cF5c1d2T6vy0B4WvKbF8zttMVLl8I6V+JkWUOQTx6alipc
# DATA FMiMr8HKXgNx1OdELHBDeXMv2zmojSvxWur5spzYodyhyTRUNKGSZAytu0qhNUhY5AqOUTKG8DSZVWRfMf+U115ErHUi03je2gUd
# DATA RszTeVdTAQ+ogsqUG3lCT4UUDekd+9iJKFSgPbDJWH6SXs6MHOjyaTH00+cizD7WjJzTjr1KyfRnYynlqqUzlpyxtMxYynVVzs38
# DATA 0ruZVxpZz15TXdd8qs4By0ofwgMwpvt4M1KmsT5J0DQhAzzXyPZmND9mV3MSKg3sBXlvai5GAdxSBo/VFJ/r0JxjOWc1LIqom/to
# DATA XNXNmEckKl2jr4xhM+73vWA/jnq8+jmOo5Rd4onW1JbuIAOPZwnTim4l7xEN0V6fQhMR9ZTXSeUoMQbfocQl5f2LCOTQaIFTzzLr
# DATA pNToZ1Mx3FhGDszvnibCIcYl7z2ls+2Nom4STwbsgFH4uDDoslsez1MOQLca3ddyT3zm7gnY1hgrNXidKY/CqZgRaSb9PIyxkWUK
# DATA mq9swJsEDDW0uj0N0Ct5d5GZFHQ0mSjwNoJgl9xtDwvbuMro7UDussvcwxkJ9MVj5I5Gv0u6OVXeAb2NV8bXJO/9AHaNcIv3YqM6
# DATA j6tsblFJwCyWAtbYeSp1qeTTeBQnSXyg9L2l+vMquS4arvqeZOIY+zrjWRcaMIxBF99Vdog3S5sw3A00nYoKA5+iLK9Lz5ssz8+e
# DATA MSzwLAByhmTR8RQkhLUoFqhShI8xSE15CBuQyWAbltQmMWlgUy8V05Bu7+OEOpqCGQelOgCHKJgAvOhJyPB51DzKxpEUEpOnybLc
# DATA Q1UegkRPkZmNMTBjTSmepPOJFHvqJFLQ61LPeeUK8ZEclVyYzXuEEW0ebHIbaa1et6gdxxjmVnqV1zmR8wslphTWZF7mV+ZXnvO1
# DATA vryWfpFmZRrfxb6Gl0uk0WQsLGEWcCO62LfxgslDLllTWafodKxOGC3lYt/KSyfY9726YeZfeHM2PKcv/sWd/WSIS3pbL46T1OZb
# DATA /svR98d/CyDl8T8yd/JXTLj84vi3R/8DRMmjb46+XgRc/gsTLIGn/MI7+hb/MMzy26Nvjv/WY/TlF8d/T3++FMKlCphexFjL7yjw
# DATA r4/+rOmVDMak274F5fLr43+g3/7oEJbXf972SGZaSQwjiU1hLBrFs73BlBk5IjOthtdhNIW6hpwiNhOx2VjbLmRKYdQLGN4qAz5b
# DATA MKnM3IBBgVkY8BnUtfzKR7zjgvrCaOh9QhYjG1GOZJnN4XQvcNUYy6UFc3lAS66XqTV/1NVUkEf5m1FZza0PVM3F8HaRNEsyVllI
# DATA Qa1hyl4TahITR7LcoLQuHGR5V22tGlLzOCweBMMnGamJzGrwdoD/UcmCrdsNcNyIRtkE8mwKrxP0MEIYaNQ4DMnIxwI81ctDnhso
# DATA ChLOz08WSJYn1LzVZsmy5vSsiJYnJMLxLN0Yf54xXsMszzq0vxSu2Ssb1i9nVN9oUD/NmH4FQ7rUyyU5YAb0Z9h+LoNwuSSpHs1D
# DATA 6ROz5wK1TCrJRSwLvM4ZINujLsZZpJiTuyzKvPFZPZzEAgqUvqmDdXOOb8BxG+dQe5vALXOObkRJJcNof7K7G1v9vAOaY2MNWJQP
# DATA UqECej9NMxNKRn6y3LDLu08xi2AICJowGvPakqFdwtqJ5AXKM4xC44WsuxYaUvlWeyGNkaOIzIaDQcixCDw2TXiDXT90tEtHu3S0
# DATA y0ukXW4yxGw0pdnIJr5q8/4s1v25jXuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8dMhLh7x0yEuHvHTIS4e8
# DATA dMhLh7x0yEuHvHTIS4e8dMjLa4O8rNRqQb1xVuRlK2x3+s8R8nLJyvNp4Ze1ildrNDzKN8+vlod+ue75zfK7tWbLa7aGlVbFq7bm
# DATA uJZ0b2cRhzny21WvQhld94st+rvttRvFWr3o+8UKhV//xXs1n8Ju1YeNatEvN71W0/MrzWKdbqkVq/T6drFSL1abc2VSD5ud3iIf
# DATA sErRbn7q18vFetmrtHyvPK1VW155v9l6u1bNh9HotnrNymIYrZpXr5U/LVbKzWKLIlWpFX3KC4pRHTEttponkDVN5BY4en5LXteN
# DATA EsyWulz8DY6E1+Wi9aXmJgIqzMW3V2/VarUz0PK4/mpanjQFi5bXadTDqr8BLa/RC3O0vLDZq7c7GS2v3m/Atja0vGqn1qpktLxW
# DATA s+b74aXT8rjaF9cbBuzdn/NNU1Hh7OXnVgDaNsix0yTRizg3la+L/j/8oRZ++6Q1hOXGzir4mxXLkyl8NmRPHjwdZK+2CNnLgjkF
# DATA ZE87IFfmkZ3TKkMVxk7VP9tjVGE7jY0BM4it2Eagx261wFVezb7L8rVgZ9Uac+KEnDBEOwefc/A5B59z8DkHn3PwOQefc/A5B59z
# DATA 8DkHn3PwuZcIPsdpw2mEorZ5KI2vrRvQGEEkOcRyQ0v7U8/Qx9AbDHfvbA8X+E4qxTu6I3uNgnn6kUxrfu7hw86NYb6Scc3fKX0S
# DATA R2MK4EP6D3yo28a8/HBLHzvP4lKaPkW+frj1xsKJdBXADXzWpKh7ZoeCDlWDnzRbySmEu4PVaw5WuwPVL8mB6tPqhT/bg9bsl8xc
# DATA aYs4omFOC3Mvjns4W+yxn9Acs2WSBAJZo7P9rM9nPw9nFPnvC9ZqX3aQ/KJV25efy1+q377BMfnMT2v0w0MRqENpa9lJVTmMxszj
# DATA kKKQxqMQQjB8tFaqGp+AV+43JrKIbmD+fHl2crwAGWSyNbPGznNG6JnCAxz3+3BM6wPNonuIwKWq8SvmD5+fRkR8oZrIgdwgs06e
# DATA jVjNszjNap53BpUzqJao0WUVygnWOMGas9pRK+21yxGy4T5dNwOypES7gjUwBvE03kuCycASFX9mumkXALCkcfkNJUNjjV6n1CwW
# DATA YwCBXKBgsRr79WA+CiacOdaYv0z59kJUiz9geW/pG6k2QiEFPd8lCBe/CVudXzT2wqeUj146vnD5YBYtfmeczobBVNTLD1XyDpDQ
# DATA CXXifY/6u+HwMmSLZ6ypNNXcmRlrgM+1hot9b12UpyHx3fNEhF6PczT8Xey7mP74IExSlmLCShXz7UUWhtlGxSAiA342oQYZXrAa
# DATA dTPrROcsaCrOADxYYYCIwX3BEtFzrMlsWiZB5h2T9JDWCvJGh8b8kN7G4CgzAKStqG6WgzJFeUwO7PqjmtBhpj4lA5qcOEpXSEt1
# DATA AVjUulKWLhVUgVhcynsEge9w7DF4ZdylgtLyU31FPaC8LxiFrFj1zlrSFAtPh1oriWdEyazTgUg+lwsziVFN4iHji2UcEI2jZAYh
# DATA L09nmtHxUu7NUF5gFrsDpZu6GerxxZl+WAaFm4C4CcjCBCRvYbopiJuC5KcgKycWz1pLU/E6mGkxCCYMGw4ww7DFsdNQ6e5pKcg5
# DATA sUhG7Wh1SIU+CmUyY+k8Tm0BSIyVwwPwk2aCC5mXeJQWO6OmTH0XlcJ+uETpcVO1TU7t5M6bvLSZxbtzmM2OmLvcmUXDntHiU5Fh
# DATA R+Oi21gdHrUA9Bq9Lav9DKzCJ2VhKQtI/5jBs80VVhEYMCuGezZZnJXdKzR0W0nJQ8DVe80WAlil6vOrsjFCvdy6w/Ss9lOvxtzD
# DATA ZoYf1uAxxlKzUfexbRkrR+787TRBVYcZ3uJPq+/sDqNRhyOKD6vvo445xqYsuvO+fMzuvSlpuzOHKde2pqzG26YmRpQ1hmaudLEZ
# DATA WJq9OiOdWc5B0jPTU978IBNVlY/5fJgDc/FOatMdyM4CmdjO+Paa92RkkjEfb5OpUI6s3nkYMaupFzJMiFprVbwEozidDg8V/BI/
# DATA wUo0Uuy8ViO8rmg8lSEwFDlM7JJMB7HSEw0Eeq7FYxkoPjZSs9RyeVqs3dtKCtODZaasQ3VQ62ozsHGKDPyA5sRD9t1HSZemi1kW
# DATA Yo5KHQNQXHZHp2Y58JRQt/CJ2qJDPdk9XiVg25j3VsJsH8UdPEK9Xyh1moriSSqLZooCxmVxEdlltZJT5ld7bX6ZJicZ9hNIflK7
# DATA 2AtNVsGbwPfk88gguCQjS94HNGYWPFbJi8gIO1T+JwURo+5cKHGyW0XcYZozT8MGY9zC3kVklel4TplRzbUZpXoxyaa34ccRcz4a
# DATA W7WKX00V4oBimbIjJkiGavVU+2bgRMA2uABatbLSxdNs/Azv395h5i8MsQSIPflCzgVwjPs8boeQ1GV0Bd/0TNtk/RRt8l2A6NCn
# DATA UbsrUqKLArkytc2+TM1NqHUqI62VtzBID7G4p4lw9AjZ/CI9zPkptkgKjJc1I3+WFcyvbF7D3o2piGmMHIaH7CbI6tiQfsksHOXd
# DATA FYcfzW6pCbInLjPWkCHUw7PDSi+iqkVRsbagDowTObGqo2StiAsKNMIk6i7Nt/xALHvr7IHYXJFsuPN+rHfBaeVpNsHU7jQ4RVRJ
# DATA Kkq0zu/SSQyxF8UBkbHEJuEUaF4bJfbfBSTmHf3h6CuPsV6gf/35+L8cfXX056NvFjFi/8/R10ffFo/+BADY8a8BIPt34MKOf0XX
# DATA /+3oO/r7d/T390e/P/reO/5SQkfQ3wA69tXRn45/c/Tt8Zf072/xJrDI6M0UxlcUwlcaTPbno68cTew5oECPZeUH+3i6SqU+o0BP
# DATA wnjC/EYGrPPQTm1PDMReDOVz9jZioLFc0koMl+9CH50Jq/MbqAeJREKencdrqWJvwVxidvv40OHEbB+K6giumiaWL5DLxYhFY2sN
# DATA 976upfqXRZbYeIpDgKaPxVcZ6cLkInliwVQQBYMgpeEUFixZunG/73Bim5bahTPF7gXDLlYdQ1kAO8wA1cGId9rzEsiQ10m8PqYS
# DATA HnPhWO7PrHKApDsahTz5xVjC64jRL0Kmb3i9KJwuwYidWOlWWye5tvTsGGInpsBxxNzofhGju+aJnXpQfykWRa5qQL/g8XzjxZBT
# DATA jeZXNJhLjbTzINtu9eybzmWgxOy0imNY7eAYxPQcFh/yCUUKTCx1YWGRaE3S3wGDfThJharESZsG6RO1VwURiMY4OYZjfCpLNkOJ
# DATA AWAkQ/U+eF0K1tTLyE5SbWRY72qbAPCpGBvtYBNgbSsiA2GJXTCD7kI0XWYPKGuAwUewA7B6lT6hwEw8IjjHuTZR/Rpilzb2kM2m
# DATA SSRlFo+7YTJOHUfMccQcR+ySOWIbjTQbnsDY0Di+MiP/bL7HCzDxHU3M0cQcTczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQc
# DATA TczRxBxNzNHEHE3M0cQcTczRxBxNzNHEHE3M0cQcTczRxK4PTaxbryySrjalifX7tbD1HNHE7GXn02LE/HrVq7abnxar5aJP+dOs
# DATA Fv16Y1isAavlf+r71WLd82sVzy9XvGal2PRwF+7wW8CA5bOu12+3m/0FwhgAX7Vy26vQO2pNr9YutulCxWs1EGTdqwPj5fkIu43X
# DATA Vdv5YOuNVq/VXwLmqpYtMFelXTdgLr+crw+dWrMWLgmgXrMCqFpkr9ZilagtI4NVmqd93sqXarXpVSkfKnWvVaS/fH9UqfmURx4y
# DATA t8xZvDohdinSnbV6fVBvtuZIZ+aBBdJZ4wycMm4ZhlPGjczilFE9ajaDDThlQb+a45T1K71mt2FxytqNfjPjlPVa3VqnlnHKKq1G
# DATA tdG8dE7ZJJyeSCnD+KLv2wDzZTnKquwmK7V4eQxD2s4iCcyErDFnuZlurf4jr05/KnV2OubQXJKjEoKK8GZONZUq41irmOnu3Nsr
# DATA NfYFshtvzrYRz9MahJdOVyEXvzVDeO427QJzyC6H7HLILofscsguh+xyyC6H7HLILofscsguh+x6yZBdyuKwOFy94DDdfS+YDkr9
# DATA YUwTG5h9H27hMBal/scwaW6qa3w+ChflK02zYKhSq2Hr88OtuxOa4D2FizIcHlJu3EDQNyhX+jORC+PjYX1L50qdteJVJJCygNTS
# DATA h7kCdTgLGmQIUo7dBHxIGwdUzBks0ftzlC137Pi0x47dceMX9bjxWfBa1+AYMrvvtL9rPWVLBKxMvJceVV7C17ouh5efqzN8lwHc
# DATA yh+3vmDS1lxlOCtiy3KkZofIVU5nWBDIM4qAvFJd4ewaVO+8yRN81pXTOnRcfSAUOlZ6c3IQ1lSfg4Ce6MQHOO0c7s2GkO/TsnMj
# DATA yInGfajh92YJV9AgGWnpe3Umnt+tI3CXbOuIjF/eNqujoClhlD19LJJ2WItzCj+Rx5tTxDLBUuuQ0wY9O24LOFHZCfHiHtlks6Rj
# DATA hCdfkqOeVhjOrnJ21RqxNrtyOV0Xp+tyWoNqDW7rcvRe/nocH6D7F8WBTrAnGmuQ3FADm3/1cmIXQNfiFQi1A0Rfy2nD80Sfrv50
# DATA DL2FUMmwGLeYt/1kb2eOBDTmdaAMtKOCMN2U/p7DIVGiqUuGnswoYnnbcgl9NvUssiVHjCPs5cx+XCFnL34IAH1swZYJtrjSYL99
# DATA Ynz181m/qi9kEK5WeVmc7Rhju44d5TURZk8JU5rgrs50bJBRJ8RVPWqiqr/ncGFr4+mvieUcQUmtL6G1KqeLqJFzVbcoSahUd16V
# DATA vaYqnmqN0dbyzS5J7xLtSwpo/FXM1psSxPkoUBazyWrftvCR0qdXiJcAzd7oA96H68luwNygWSslfBqJigsPd+hxtAvq0xn1QtAq
# DATA T2d7eyF7oAGM4JUJ1UHECTAWgCqxqjRGYQ50DEDFUNO4hIHGvnHV7iCgQqb8jP3xVDTQg4FCcLBnGLFQoIJxmspI3ov6LJ0yFf0h
# DATA Vnb21Fbe0MRH5OghTcTRWKJOlEkSsawyPI2IjBdMqM5hgNuU7fSCGLu5EcyZu87cXWnuLpg2zuJ1Fu9qE/aaKBzeY/U9aBb3MchE
# DATA Y5YxW8530nzZTAowCUcRIzoKq1T33hSm4MJww8Jme7OoB5xhNjBSaNReezMACHl4mzeB89CEBYFDcx+N64Zpqn1PPNT/lDkBGM+S
# DATA mIaOYKrHXLbDR9TAZzChlB0Q7CWhxlcuDplK/5BC6tFQbZIDV9XCwMnSgBCXYc9RyJpwXjBFhaYI37ap7ZoMGT7l7VF4RwSoAeX6
# DATA ihmBSLzF+7y/STE4NT93ohle2MgpoJCnYdKNsN8xB0GVDOeCYdE+S6hQeclK3lvgbHE3yt40hnYNYHPxXQwwAbES7rp3wyn3s5wM
# DATA mDbBdM7fhoNrJrIeH24A+2RdGu9qOUrT3+tEfoBZm2bvqL4fKpMF0dzTYCI8gvVHKuhhWmA6RmqondroEjPpfQSGnvIQJpjaaMkj
# DATA S8JDUgeWdtiLuoGUoMJnIisXarqFOQuf0pg3PFyXyvf5SLExvxhfotN5l3d6qkMis6QATzIrjI908fP0UZFyIsBPlPk6hhKfEv+0
# DATA GGmcpLxSZcl7FIZPmBICtyzzPJCXfKuqFlqxMseXYf+pcEOgtggHsXYUBylPaoO9cZxG6QKZgw2xk3S+H8fUMXF+Zl0Qt5pTk6LZ
# DATA p63HoAvhRFtubtUY4N5mJ/YlkKHfQ/XV+2CouQaouqL/rqcpl0CJvpdzlqPNUnkLXfYSSNHvRlOelSXUbUEIUqCQilnDPacITF4C
# DATA LPrBUN6JDpJTmzUunmb1LgEUfZc6IN3i0Uv1jL4uFym8RUnvgtnJL/r8zeLi0FPT1Mbi/DMgOEffHX11/Ouj747/8ehr7/gLIGro
# DATA 69d0+Zvj3y6Scf6FUTf/ylCb/N1Hf2RKjkc//erod0dfH/+DCuW/gotD174//ls8Qa/6Lf3yZ3rhH73jv8uRdiyYjkPjPAdkYQaz
# DATA Ge1aYWTB8wukR0G2oQoXuM/d1gGg3AfKotoLWTH4CRzOghOealYiQ0Z5EAVDcG+4noDzbhj0+S0Of5ObY3J7v2r6jVUYl4e+kaRl
# DATA 3SLXnT7Pw+ZvxchhbuSpXjI4nA5GF4m74U22NO0ZoMb3eEYA5B5vxcTtDntzYoldOO8Gk9y4gzkm1zPtscZOETUd5v5lGCQjtTSV
# DATA TT6jVFzRC3uoRT+dbVuZS1BpUS+GaR2ZLnBwL+Bv1te/1cZH1o6eFfZmfcwd8cYN2qcYtDXY5nRj9cvhC76acfoih+mNRunNB+nL
# DATA H6Ol+plEmwH56trCZZBqTHqEkJzOJ0Tvv8g2MbA9MYhHGgZjlYnMdGlAw2AX9DihTEE3RIpUMZa78SwRNkU2vuqEy1F2egnyioPf
# DATA jFujpvi5MTgwznU9eptxO6Ube7NhqLdE8hIWvIpeOgm7UZgWTPwzdrFytA4jcb2G1NkG/XB6mHMFqnQwTpcx0YwC7kqi8glygBoH
# DATA qHGAmosH1Jw8cGw059jEfr0a+/ss5vd5rW8Ho3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3EwGgejcTAaB6NxMBoHo3Ew
# DATA GgejcTAaB6NxMBoHo3EwGgejcTCa6wOjqdbCau+sMBq/X3+uYDRmufm0JJpqpeVVa+UB42cqNc+vVd+u1iv57Oj2W+X6Iv+kRgmo
# DATA 1po/8yvVef5Jrd6ttZbxT7iU8sFU222vUqv8J79d8SqVMv1pem3/U7/e8lqe36x4ft2nd1W9Srv6acVvFP0qlSGIObWi36BbivSN
# DATA bqrRTT49UPtPlTY9WvGqFEK19akPL3LNq9E91UYuXbWw1W6UFwExEqEimfBF32+N/BrlC17UKAPPM5fWbrvXDrrL0qrQM1SKEZkf
# DATA il1TK9czdk2tXbYqcE2+HC6pzb1u2Oj2z8CO4Yps2DHcJix2TK3SDOrVE9kxnX6v38ixYyg+rW7HYsdUG20OSNgx1Em0g9Bix9Tr
# DATA nWrt0tkxQ2oFJ8Jj4DT6PLvVUF4sjotK3aJjj517Ffq39SPb3G6y+ZAFeTKSxubN8GY72Vu8LBbGdVVasn5KFpaHpUqvIX9yoXnK
# DATA ojFAGR5FTe+fI9dIEc+lmMKEZeTV5Y9xjUqyWzCubH+Ob63xqCCalGE+/VH/aguTrVceEFfSajYoy3zW5efYSzNiZUAOauOgNg5q
# DATA 46A2DmrjoDYOauOgNg5q46A2DmrjoDYvGdRGG4Ra2mdr57V1oxnDb3Svz6cu1GMF9IFLu1ZPpcyqVLt3It177bJJvHMb7fzDrXuZ
# DATA mhcOq1hyLmPKYaXpgulrnlljTj64c8Pu3LB18sWdHnanh086PbxSa/JSThW/jpoLpbkscHOy+JnqT1yAXjq05vDmgzB8wiccpc2e
# DATA UWsuG1suTm0uDIdKlbsjqySUIVp9UDm6L0F2Tp83VuC2CZVqL4H2nEdzpHB4eAmac++Mcah5Kj1sqpSyYS/3M4HqSxCfe8yuL5VG
# DATA MkFUb051gsaOItSve5egO/dQjhLDB0imnEqygQtcSrmy9tz7OGsdGAE6tDwZ4WCykHmJvVCzJLxg9TnlgTHS8ZkmY04ZIDvcqhNi
# DATA Ts1ShqELmOZ6EEuiPhOFFwl4SKjOHdbn3qiUqWv2kkOd0RmqIRgegFs4CllCHrdgoYoMjeGw5L0b9U1zKAD3MFxsi0pFdYyoJN6A
# DATA fkxCLFgND+VJ7l4OglSio4lCSq2W66CovKOxwZsr2tU0qcAS+74KgFoHRVPqywC+wUSdiIdOJj3apyFllWSAzhV93J+6yTFOvvM2
# DATA AxpPWAqARup5iZ+5kephiOOA6hS3TFrlDhl3TpaNf85PHjvkpLPfM/vdWewvnMV+WqTkM9QB4sV8sxC9niP5ZsTy5wqOAtHzscd7
# DATA eddAJK9YPujay2lcBh8yEzm6aDikLQd1VjKktUlBT5se4liVqQ4y8WPhFCU8VZkrSOxqkFJUuxtBbHw9kYdBA8AWOg1tvOsNZ6No
# DATA HM9oimhsojFV8hgiNpNwOIS0O8bQgVJcJ/trXPJ+0hG5fTJMsOkaWkoDMkkV5oB5NvrtdjTegoHGd3FidCzeh11EQVDsqPJSrbHM
# DATA Ljb5+PxIyNsQDlNoqQcpS6hLC9EazyNIWCfr3s9uaC/37rekBaVkXqa8FF3y3ovTqbb/RFyI2T861reRQdK+wF6C8g3117ANIGxP
# DATA 3QhVdZYNmY/Jiy4SY/UMzlZztpo9Mjhn68vrbF3NnHyWEo7v8WKlrs9KgI2PXltQSkjrMRxhH9pt0n4y502B3QgMmGQnmnYclrwH
# DATA mRggTuGISptB+3AZstMgsPQD2afJvoN+1PVSmu53jWelw1vJMs1A0VzcUAOSUyyOj6zxy1ofYjIOkkTzhPhwCd4Dr88SI1GdcVyk
# DATA Xap1blRS/qT8ZMqTpX/MgIjmCuc4sCMhhyNPK/dTPBxaKVhKgDSL51xN5POrsiVAvdy6w3SU9lOvxtxhZu47rD5jxBwO9dJoBH9o
# DATA rKy5+dvJbuBWFR+svmePzR5GZvGn1Xd22E5jjexErBR9501JVZYPMh5rb6GsQNt+PgwNa1yFa21Gy/MZJD3jhOcFf3HHqxy0cmAO
# DATA JMU7g03rl6V0rkLJjHPirknAfIwlLydssN2DiGOUQMgU9T4zW2GvFZUmZ0EkRouYmWkNUhrGRnEvZD/+FPYsDD9twQlKyXYmwgFp
# DATA pDpDFhrSRvbU+wUNuCXbv7qhL9Uz2+TY0sgnxWSNljAD4BXL3dyI6BnL6Tpvy56qeLLKd8oSerS6hHQ1lkJ6NGEfbL6EqBlzRyIe
# DATA d2BfoJU5IPtH3KCBJ3VdWf0WO9CsgeB5WQURqdUY6qOYcqB0sYNRWSnnLxs7Bde/YB5sWjAPgmTIorLBcKQL5lHcZxjrmEY11kw9
# DATA wCSPRtC9/Nys5N3djyPMjCnvjVu/YLu+uVQm1L9gctZTs0RMD89dHnbEr6w8sr73lOXxV6vLQ/fiUh5/RQbLQkc263ZnQ1aTxSKg
# DATA OkmoGoeerCqWHvVSvJKA89g0ZJS8t6l1HRaoCMkMiaOhqByPuBeLRyORfybjYiQsMfopQg6a9eLzF1SWoutfTA83LaaHs05nvj97
# DATA nUWsVW8Wjj+JD7MeTItxlbwPIpru9mbU0e/JUpSRT9arQpmFB6Y25VU3mAkd79xlYUf7+ndib27aib0eJT3eMTCGA4gax9hqPANR
# DATA vB7MRlGviIVClhhX5cGjTsqGPaSFprDMPwg0lzpb57d5eyhh09tRSGQ8qW0T0EKGe+jc5bSYoDOVVt7+k22Mtv1nrkje33k/1hsO
# DATA tQa3mPxicfPSP0MtA5qxIDt0KauF08thoj3XHq+MhZYO4jCHQvu/jv71+Muj3x3/BqwyYMzo86+Ovj76t6Pv6O/fMR7tjx7Dzr45
# DATA +tPxbxbBaP/MGLWvjv5Ez/7eo784wKNvChTi0R/oG6PP6H/fH31tXmKT1OimPx99jU+Ko/ZvoKLh/fLe74/+/fgfHRXtOYBym20O
# DATA vOU1nh5o7Kohc0O8WMirBZ4Z8TarECaeZgEAGgp3AsvIUAcgcAZ0oBPQDRTRlepxMuU9Y3iuL0tYxikAT8dachqU5dEUxM53+DTb
# DATA 18ddxFXT0+YL5PIQajRaBMN4L0N88Q5Dfvk8h/tmP8q66TejqYXvuDiGGkxpdW4DNTSWEZyzweHTTi6tC+envScYcK9DxgV2dNG8
# DATA f0DjjpleFrSRlcY4DIWMhCGLZKK7U3taMb9RpPGnUEkJs86Jdb4KZFPJcmQSsmeRCbP6mMCIikjwGhispgtstfX1crURM9fKnhVg
# DATA bX30HWDNjf8XPP5rCNsZhv2XYnnvaob8Cx/xNxrwTzHeX/5wLxUxn3Qzyl+v5nMZ3LZ8wnmQ5Awx0DGT6s4hQirIGcZkJq+SuE4F
# DATA 6JSOAix8maU3T/qlTpjCpRUmWJrkRNNAnR1bUNHrRX3DdqNkH3qKZLIhsy1R5hpvq8GRFTIo2C8Rdp9gbFJoMq5jwr3iU8O8E0ho
# DATA c1HKe6jSqdC4eGk2TKdiKiBfMsvhtqKYgZ41nVEIo2A86+NzYhsJyvMKPwHbNMlhMR47ZJtDtjlk2yUi2zYYXTaa6GxiEl+hXX8W
# DATA s/68Vr0DtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXCbA7c5cJsDtzlwmwO3OXDb
# DATA tQG3+fVqt1o+K7it3m+E/ecI3JZfcz4tvY1sVa9aa33aqBerDa9VLfrVypD+qVS8Vt3zy/RL1fMr9KlRrFSHjbZXb3jtsldpflqt
# DATA 0VWvWvdqlbd9v/1psVWsNr2KX6zPZWnY7ld6nTnomd+sNaq1ZdCz9mLJVcperVwf1JuV/Wrjbfqaf4EJK09hq1AKKo261/SLfmtU
# DATA rDW9Wstrlot+k77UvFrDa7Toy8YR86sLMav7gMQ1Py1WqVCLyIvGexQAYjus0oUcLY53cuZfFvabjRWYO1WBu1HCJ+yeSqWvZOg3
# DATA v8kgOVY1aORbgAmWAoBh48nTZWStJw+3Wvlq3+/zd93/shwqi79WW1RvKIxTYuO4GWlsnLRICxsX1lu1ej2PjaObapVGDhs3B5IT
# DATA bFy7186wcbVuo15vZti4Xrfb6WfYuHav2i6Hl46NQ/s7GRtX1UaBmAT6mRX8OCRzzr9Y/5FXoz9V+tOo/8gOYo4X986IphLTArYC
# DATA I77e+6zYQV/tmNvTpHq5fHvemSfunkJr/6DAq2QrVsRUNACvmny26VJBqWblhVdN8sF4ej9FziAx8yXsqtYuPu3lzDPtVCZV6I9f
# DATA 1yY/+4qiKVlY3RzITvuwqV+uLODnyqv5cib3C3YOrDFFTkggWwmOI+c4co4j5zhyjiPnOHKOI+c4co4j5zhyjiPnOHIvGUdOWRz5
# DATA DiAaU/i7sPc+3JI2Rwm/Id+hCMPZwCbmh1uPgwQqtPyIJzejed3gC1Qt3sRmum1/5wblRndU+pD+G9+1Tonf/2n+GB4//F4wHZR4
# DATA hr7N4fzYL9URQna8b8mh8Uz5FlJcptvXqLns2Io7RO0OUW9yiNo+2uTOUruz1Gv0kp/tGWs5GlzQZ32XnLR+aM4FSh0p5JXVzKFe
# DATA ObCqBFn4LDHs6AOlwywneUNW2c8OT06CQ0ym5fAktFbG1snJjTWQ3xTV444wonogUOHVgenQ0RE43eNNdI+7QToLlGwaPq2+E10q
# DATA ZS1u/UA+rr6XOtheHHNG/0Q+Pg8KyFlenFIE8d5qEUSdqyKCSEZZctiDDlEw3g/STAERJyepeUFBvBuz22Q2meDcMzYa4DCal4gs
# DATA ZAo8hxxmZy8YNbWw5FGrjnB0eE5Hh8fDXnJY8MIgPeSGcn7dw7k0XJlEpVX/Lk4x1NRkpVMN2yGZwYzMyqY7SwdUc0MWycUZdDlC
# DATA HYhcNZs5mREBqxJ2iWAYUFADcO/QRWTK1ErPgY+Hz1A/4C/taObJudSpswQ8BwXzwcYF85CqehFulUNogFvKoXywuUAlMgm59XCz
# DATA 0Q2EQTIoOOqP0HC0bijOEUKxCorh4YRtQ2S4paYhggNY25LxLRoO4hlLj55f3zWXlCsrpTN3bu9u2rm9F2HnDDQ8ZomljEwTFJrz
# DATA YVfgNJ7optOPkhHESWcTTxVMnLAEG/8q6iUHlKgk7kh3l4T4yrphs/GAjCqoG9gyHucpklzMr6xErEHylEXyeHWRmOFWyuRxEkRD
# DATA 0UsJyKwxhULfpzBOYL/FksM9mvbAyEPVNDTMJFDNQWlWAyaslWYyJYlM7E1EWIaHovZ27oLJR//6t5VHm7aVD2ROShPUaEJV2BQM
# DATA ajcsZ5q6yxYhGNY8jPN0FKoek5THe0zzwaPFxlyFzEpFM1yJhE9Z1BqlC8/puYtiLsYvr9bxiyAnoh933i3n3drEu2VXMefdct6t
# DATA jb1YK51gl+PdYuEtA8ALvL04FlE87du6tvq163xfONLg2R6wBaeW0E2xYUTtQ9bXct4mtTzDaKYx9t/zRFUtlG53RzvK7aUbpkxK
# DATA UYoSqnnedGXZFeP6qfDu2gQ9N3qxUcQGUoW3VY8C3vKqN/KGE956XfJXO8h4BQm1PFblOjGqZXk/mbrRxEw/uOCa8hWhF3ZP75bn
# DATA e93Raj+WX6qzA4ECi8KE7i7Vc/cv+LKUhWUchbLphoK4r+UL53pZy0xC+VEU+HCRTpXsvrJNl+ySNPFIzLMJjYdT2ZB+U4I4pwEk
# DATA RgoGI6u92WqWjxNxvwoxFv3Agkr0kPUax9pLW5AZA9tw7BUJ9oJIdl1hS7xgpGj2UPIM5C6rpyWPC63Ag58FZGHxyixI6FWm2jrG
# DATA 62BNTaKxYKwQJlnERoIQC4qsoIZDY5B07BxK8xRhvgAKlPYqYjrbA7+Wdwpka5hq2jrWEpSsV5nJTs7YQj30zHYBvSduwjaMxssi
# DATA q194wzMbapzp6UzPTUxPZ2u+uLbmSuvwGqpV84kOc7pg0QwbWmboWzA7OVagkCehLBOm2grNHmLZJe58r5+69fWXfOW/5ZzOnVep
# DATA B51vWPpYIMI1R7hacsLPOrMoF4Ihf5sX4Z4/rifNtBtjsiDvOhx3xfw2+ld3frJw2o938FEhLoibW0/xF07LBsLi2bEVbY/NwcEP
# DATA gkOevkDP2Rhm93jJTiZHY7MoCH/iHoU0OZTlRZk7gUY4CfZ57lLyHvJy1lRbUOoeZZ+hVsJlLM44Nnjm17oCrIeTlaZpHRtVgvnK
# DATA dP/pZIhQ0+gptq7LMqRU7yuHe1y58ZRhyqhC7YfDvRl1Fzas7F+Ovzz+NWPJQBD7hj//Cegyxob9HkQx/HL85SKl7H83P/7q6Nuj
# DATA b4Ai+3e+8PvjL4/+hEsF7+gPR18xiuzX+I4b+HXHf09/ACL7Hb0OILNv6OevGGX2LQXwHX47/oKC+RawsuMvPArjK7rw97gINJpj
# DATA lz0X1iHSxlMv+ENYrlzX3lsgkgbJE6zyBeOwALcHzUoTnjtOApn+YJChGSqOSvMaEvQyvNmYA2Nt8lk0ZDYqteiAd3PSxDKYCiQ1
# DATA xFZ96szWUssEJh3KQOmgZbataHUYV40umyuVyyOX9SI5h5maO99QV7iiLtDLMO6ZO6nSSU1MLhhexvP8KOUNCGgOvDNMR9URzDYr
# DATA tQunmOnOph/xc8FQnEppdxD2ZrJNZCjseEh+MMiZezGP1V49v14cRWPY2sGQKjf2kdzWnl5GZ4gVloQUsIAUojG6YDEDlWUkbXJo
# DATA 8M2bVs3VJk6+qT0rfNnayDt6mbMALswC0Nyy0w/8L4WD6CoH/Yse8zca8k854l/6gC/1MZd4m152LZrPZXDLcin2Qpmjp+KRYgq3
# DATA F/fz+/Y4G6YDiuUer5ug0UXYp2ksI0YcjYIJJ1xeiz5Kzg1Q7QR1CUstGpkk+zV5xJV67xlxtnRDbBnnnKoUHmXHDK+TAR9AEHGX
# DATA HWjDgIogRSy9Hg784OVPxvGBnI7oqc2lwEZNQi7qQTxLwP5iBlXUiYbIKlh3DFqh8YhxUzAWRAOB8VzmDIECOY3j5fApxzFzHDPH
# DATA MbtEjtmGI81GU54N7OOrM/HPYuGf08B3IDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMgMwcycyAzBzJzIDMHMnMg
# DATA MwcycyAzBzJzIDMHMnMgMwcyuzYgs0qrVm9Wzgoy6/eDfvk5ApnlVpxPyzFrUJ6Ua4NGo7VfbdfebswjyCpho9tfzMmyT1lZG9Rb
# DATA Tf5cBWRMfa5RxvLnVsvzKYertfLIb5WL9K/67OvPc1Avyvlev7IM6lVpLUShUqcolCuf+s2y5/tAsHkVvzz14TZunYQPa9aDZnfp
# DATA m+qNBRya36yDS+ZVK8V2zfMbNUDQ/DplnF9l8lutfcLrutVGZzmtzIKoFTEdCCDQLzXaay8BmVFcMpAZRcqAzATHlrWAWrXfrGyc
# DATA v40lr6qUm9mrqr5/ia+qCpFNXlVpNC/xVfWKnapW+RJf1WAUnU5V9YIz8FRQOe7SNFROekcLKlerNKqtXh4qN4+QWwqVC/2w2atn
# DATA ULl6rxG2qgYq1210w64FlavSe1uNS4fKye7Coiwz6GGuyjMIT69OGdulJeaf/cw8FO6tkDrzKCgs0t9qy+hv8H829w8KDfF/qpBH
# DATA wWaQt1JznVtTT8+yQOcXSGzzXpfPgmdTlUwuHBa3WOH6+stOizqwXt7pdTo7zGN3LZaqVoPhrKxaY88txDk/LbpE69Ax5hxjzjHm
# DATA HGPOMeYcY84x5hxjzjHmHGPOMeYcY+4lY8yhLkRTmuEnAbTYqYLdNti53TufmTnJJN3leiK9FJ9fxtWPrJYvDX/3jmn2UX/7B/yo
# DATA arg7nykunVYughiqnPlixNGEu2oxLm9/Lq/uzWTtedcO6MeCu8OlDIHHXDpZ0rHvLfo7P/brN/w6oqNDuyMBdGY0X0Shmpix3Cwr
# DATA 0I7DsJeCd6efASRPZAhSo73UDw+kA5nIqTwR+6JLfIIxlxxkNE4x7mqzPsGLJatk8WmbJ3Q7JVl82N4OCvuFiAohuKEM7f2dH29H
# DATA 1DTKrzXKt/ydQhmbvrjVY/1pd7R7Z3t0Z9ev1cqvfbj1PlVJPmLJoSKDlOHD+dQfxjRnHd1slHd+VKnt0Aysx3pW25XCh1tl3M2P
# DATA 6WdGP6IbF2+6ndUcyXLUgO2UY62qDpxHuxy/baSeUYP/8cU/IWPT27hyY3dZYW5Hr+YL8TW/fqusc5NDvf35TumTOBrTswwulEir
# DATA jzeWvLIfjaN0oERR/bouTJyWFYeLABB/OobKhOAA8DxDD7fnKkxR14odu1pQ4+F6ZLJlhyJ5mwucSqKoZxX0/GvrTEZueWg8WTif
# DATA YRwkY0gdOtbKGVrcQoes2Yq60pl5FwWuz0OXpk/Rz1hxlLAf6TD1QzTgIiyDadQH0ZxShFOKWK8UYR1TdHoRTi/i1HoRK3VKL0VH
# DATA 4sFsmjUA3rWlNT1lZDeiEtdRxugqdOzFWBEZ90SsmDnlelzKdOv1/abzMheM0Hu5fUstmCvh+hV69GrAZUX6KU6WMw/JCHtvq5H3
# DATA JCV9E4yJUnYlU9KvlZdJ6VdtKf1mpWxr6fv11VL6lkGD6HPEaWJCsyquVnk5/dzNVr7ZQSyo5XPM7lTL2v5Yratf43jW6iff2eAw
# DATA G0vCXNDe1wcYKd18EPGOMoqFGYSWQ7fKLypnMiYUJg2cpny5acfHfCbkyum9bDzjoVAmIHesy3MFcjGvfYhxk1u8/dbs6uW8VA4+
# DATA ejTQJtRN5N6c/ynDe2blspKOID2ZwgQ8v0iEd+HfE6kbZaxoS95WzjAaMz2a0Fl2f66TZzMIwh+5W5QAL1Vh1p6B5AzraTDcgMUc
# DATA NINglQZNXnTGpoIt8r+Wc8IkA3PzB4yEeoWCfVt6CLIhYCfyDZ5/cYu8heHmJW5ecsK8JGd/uqmJm5qcPON4phJ3GONRwXUkkDnD
# DATA TOXuTTMREeABaz6ZtkalF6QscgXBKdYcMyJUBVFOGwXiuDRCaFqsYX5yMYdewDYbG/stPFrbABO+5gciPBcKYRauUrRvSgxV6NRM
# DATA aZjRRdmTfjpDNPf4t1l6SGPumJlelEDpLAoKQiTTIz3QMpCeu4v0iQ50Moin8V4STHionoQwpJW8b5Sw9JgkMT/sTQPGKr8XJ6Ks
# DATA q8a6ebipIJIty09SK+aIhUPjjgx924HCIGOboOrYxHeP1akDoMihD3dX+GmClRgENl4UHnIQBlhqDb69dbGPemzVrY38vPEoKTBI
# DATA AYEIp4YgDBX/qQE9d1kQTuEvtCZxpqwnLNu89p4qlg66bOETWL12IPV3TZruYof9OAa5dT5ZYibkubELqoqmIpNZ+ADuffVm5CuZ
# DATA bQMQfBWyQbKAfwCwF5HHWnKXZdtg1BRQicaSFDDv4L2NZ6nKDxVwRPlwdz+OeixJzSptAChIltIAFTMxdgSptQmfdOPdKcun9Bzr
# DATA vxaaiHKAy6RMxxkL6jnh6rgvszDo0I1GcU8aNwqPL5uy8vThubjfh09dl53WsJYyLHiTWYcsFOs51p/jRhj0YAF5Cddhqaw0djG8
# DATA mF/pgcROgw5Z2im1yXVJfAQ0uIJ7TTGIWEkEoUxeSD1DBG0v6u4orRN6vj8bDg8Vb0XFlN04KVdUSfcoRypkZUHpEw4GsVJHpA4S
# DATA O0GpiJMB2qEUGPr4eUStGKYvnj3taGHOlt5YDdqZzi+06XxaVtgzVoe29/yvh4U9xkigYZdsVEl9X08Luz5q0s+FpOpJBIls379m
# DATA eV0kVCyvkH3RTLF5xfGlSDHlfmM1bxQq70IjI0hqRCpmTTy03aHhRHdid95n7RLhitFUhfWJZdJE76Pfcc+bUWY5o/eAZPYYdrnQ
# DATA yKjeZPfKzAQ2rexOj2HhRZAiO1Q33YyHq5qn2Muwc1F9eWoRLHMwrsWEwBVrSM4L+uOwwFiGeJKgRqehaWai4ByY6apssyHDfoS7
# DATA yM7NeVvJ5oZosa2FzpY2TyElp2YsSq4N3IV1tgVb70Wz8jKs2UHYUeLXNtXsfzv6+uhfi8d/e/Q9U8a+Ofru6PdMF6NPx39z/MXR
# DATA VzZh7PhLXFkEnP3fuHz0O3r4a0aUfe3Rl6/o4jd0+TuQyY5+5/E9f2DG2T/Ifce/VSCzr0BSoxd8Sf/+VoHMOD5fIU7HfwcGGvPO
# DATA fn/0Pf1A9//Rsc2eF1tWGjkanhZf5yUrQ97EOhDN4URdnCdvMQU3RatHHKmV/xQqi8yQF+9RvM9eniDJvEoWCRHNYy3K7O35aDic
# DATA mW3TZh3FVdPMlhTM5RHNxKeSLrxcXZ+/XXYQmLsfhimNQF0ZsLmQLhhtJu4l0fOHa0UW/pha4MBmGxXehXPN7nqW3nk2MzA1gBeN
# DATA IaQzGzKFo3OIv3GaQrnnQD2RCIqdc+/BT+l+0TQvaE6F3u9iICZs/+wDXuzRxeECz2zDmrnaxllsds+KbrZhUhznzFkDZ7UGNNbs
# DATA bEbAS+HUukID4DLG/42G/9ON/lc4+Ev9XMgJC3X2TFrQZZDNFhLJdDPKqnQxWmCcybKyR9UTNfWWgJ4K3tuPHz94VFAHS9XKMJcM
# DATA 7xlNyH7glR1OBkZoOCUymlKiylJ7HnSe6jF3U7yZqQoe5TWUwfIGAFIWdYE5y4yAPOBskoQ9+EbyRoFtDBS4maKz8GBgjLvKPGCr
# DATA ABwqMQ8FOcXxT+k1Gd2MnSrpYcpHKdU9Hcc3c3wzxze7VL7ZZmPNRhOfUxnIV2vxn8XgvzB732HPHPbMYc8c9sxhzxz2zGHPHPbM
# DATA Yc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9sxhzxz2zGHPHPbMYc8c9uz6YM/atXajcVbsWbXf7HeeI+zZwvrzRugz
# DATA zlyVeUwJE9pWrZI7LOY3KvlcrwrLSbK9lcu4Xiush/05fFO1Va8Lqmse31STLLbiIe+WeAj7KotHdf7QWiWLRm0eW7eMF9aweGF+
# DATA u2UYVDlC2l/Wei2/WV2sOa0aVZ3WQOqclbyg0Wl3g6X8tHXJqwgp7ZKSV7FoXhsnjx66sORVhfF1ScmrqqdPlTx66FzJq1Yq16KR
# DATA VKuty2sk1YZ/jkZSbZXP3Ujs5F14I8kl79SNBMk7byOxk3fhjSSXvFM3EiTvvI2k7reuRSOpV2uX10goFudoJPVm49yNxE7ehTeS
# DATA XPJO3UiQvPM2Ejt5F95Icsk7dSNB8s7WSGxga7nl1er1/VpjUG3X9ou1xqjotxterbFfPQmguroRnIWGyZauoWGy0WzRMKudRqVV
# DATA PwsNsxwGfd+iYVYbYatmaJidbrfX61o0TL8uP18uDVNt5pXZneXsUctuho/JE3Yy0W2nWpvX2Jdsm8iFivnr4j3zWxUWl8xavGRW
# DATA amGrjCya5UJVC+ZrQ27w6ln+MT0LXL7ZMLubZpN7STDKrdGdlFz1zJLl+cUb9Er9Qp4v3p15EVftkJQX+VJE4gpYCARLDYuoT1Xt
# DATA 8ssF7XYbHpjTwTvZY7QkVew2XPA9L24XWsn9dLROR+t0tE5H63S0TkfrdLROR+t0tE5H63S0TkfrdLTOC6B1LqI596KOAihidQ6m
# DATA p4JjagYVXbnpl2uterNxOzdnUY/x4WE8phGHZJjPJrhyw8eTldptxca8r46xQz9gPB0MDw3nihGJFBOqV29if/92hbGIb0WvC1Lx
# DATA XZwzl1PKk+Es9SDY7KkX8bMqSquev+tV6j8yb8uEdmReSnmwHzKqc5vi8GOs8e8sC8lmGVrnTJ0gjBOEyQnCLB46duowTh3m7Oow
# DATA K5WUL1M1RnfWkIOQ9oLiYiUHbLThnTeWhMz10TG7CqChDJUM+pCBjFU4+OoJIEH9ZK6bT3PINrgRloIEfYsjyDeV9Z0GJ7iaJmiG
# DATA c7AE1WeEzYIlEwyKOgne9l9Hr58ERLSCM0mxr5nU1E9OS+UUyRBrAz0AvKJiEmy/d3J89XMmsuaCFdPNMn3DmGo7iNsphBIhOZLZ
# DATA LdR1TaLwpOqSBZKBJ7NLJurNk2LeWBPrlZA/0wXoKROPh6qQn3vo3zLSn7EQQ9P7oWeiOiYsD24ePSOvA9uAizQY8RyAl2dYEEbN
# DATA Nbs0qWK1aIaaYG8kTW8K3sGAKh8Zh8leaIWmcrffp762M0vg28BzNLlKQig0RVMt8KP81TLzSFmWm5WYqEodioHMOph2PSt59+IR
# DATA u8Wo6ysosZ5xz+g/ZaJLajLXkyeCROkiZbZMBpkdUbxmCftWlfjQBtTAF00pxjFP3ERgxUTA2fwvhc1/WtLJdVGKtHdKrEeevBXx
# DATA iClqibweDZG4Mav2UNsahWvZJ89OXvL5Ulc7SV16bo/HZYBPFgU0Lxp+skyHdCkAJVd2ekuMVORlgL83Yc9rE2HpHazqufaO18W0
# DATA NobGKeW+FfmPcZURCw4CJCIan8FUylyZm5vgMB9l026NV3z78XvvFrx7jx4V1Dgs7YWHBaXlDoilzItEaHECldBAK6myUiOVgpH9
# DATA jNJs3qDBdtzAoymG7TVExUfSGciGt/WwyLtWJFQl1im6CyXQsZJH5dhxgihhvRA0v3DchSLoOKT4KT3WAtVeqq4Dvcwm8qx5Vda1
# DATA aM58B3JC1LXgrFjTOtoKpsgGtzpgGIo/Q2CkMPtF+54N6ORQSWKqWJa8B5pTg5jz6pjuyAKvH0TDWbKOZvlQgsHC1Sqe5Utkgdv9
# DATA tbPBnQ2+1AZXlcR54p0nPmfdrTTer49+O9dpjNQZzjnwxFNoPPDiq4lSbNyLeZDMi49rF/o8/Ww2AU6w5P0Me8QPDaKF7ujNuhCR
# DATA GWEsNtLGxt/ORGO2dzYWcs90C6R54uudV7Xh9wjHvLlhQ78iVQBsmXGovuDVm8ZKnErvPU3wUYS58aquOOvJ3khiGoOpYQ+W3vBT
# DATA GdP7oDavuOUDmGxIpWhxs9g0br2Jd97U75fBaD4aylBVBpyxePhNvTtvqM2JXIMLHoaVPvX9MZUZYz+pqk17fKcaIwqeDMYFLbUN
# DATA zh0wxelAwu2paK2Ix3vBmOpUz7YFTWTuZhL4c79LFGzTzdhfVKJJCPFuXjzQltfJEflZlExnUFRnKXErDqqA2czj2sqS8tynJPHQ
# DATA ROYnE1ZUMTdQJQ+nrJI+4cGTMmg41FU9teJzUxXUTVXpVnDp12O/H2k7L8t7MfmC3ogGfT3Lydg+WklckdrTQTwb9rhdijk7huWH
# DATA jeeYWom6uhRwyWP7kizgYXw44iDIPgfPOoA4vCVDDxb9J3GHB04lMT8bMwtRhbQOCD6OD5ReuTadg+lAR/+DhOXsqd57LG4izm5e
# DATA b9F+Y3Y6kzVOwQTa24xeijo7vgc/MCM1s3GBhAJkUd/OEyOQ6sdwsNNwHo71vT3FeszWBtcl5j1xRav0BCKeD7+6ce8rzzoiptcz
# DATA Mq7CIBxOVH8mC55WX8Qy+DRQxjmowiQMnqCEpcdE3cOaZS8c4QX2DEuBFSgUmQ8yFh6twJ6aKTvGBp+b9U/Uz2i0IUP8xbLtP//8
# DATA o88/HG+98hcv+n+U9eHwY3QY0XgGqOrk8MLfgbXLRq32F2rdeO5fv1yvV/6inP33F2Xfb5Ybf+GVryIDZmhz9Pq/eDn/++EPf/hw
# DATA JoSILnUgUY/HGVSKrZT3IhcZ+5FVEO/eu+9Qr8HLnNS+42GPl/DpgRKF9YpIpZBtu8eHbfT3T8g+1J/j9BUevdDpD6OOpy4/oK/6
# DATA lsQ8mM46yj+jr+BIFoYD/X1Gpssrr3zw8O6DB/cfYgP11tbWK3zG5hW1wbIv+6rZ2bRNk8leeKufbu3wbkacDNkCg+8m9Yo3QfW9
# DATA 2R1GNIPZuv2KbLXupyXkA9x8jw7H3W08VPC2aL7e2rJ2oG6xU6iI0ItZbm3t7Gj/Uil8Gk23/Z3br8zv+8xHjc+RfaweojdQ73gw
# DATA 5jdnAYVd5FbB+7mKzPJ3f1R4xfO8z6ZyiuSWz9sdCqPg6euzPvY++o1qq1Z4Qlbmo2hvHAxvbT16562/fufdd7cK6bQXxbd+vkXX
# DATA aXjYKmxNogn+Ud8/+nxHZY/amBomCQ09v/yl3qiacoD2BV4sl42vq7NE9hDv5k5r6ed7GAumsTpWofJfR4MffI0L6pBfgoNReP0P
# DATA 5PBQKUofBf3wHbKL9nBIAbeXkF/3sJK9gzvnrnmveuVll+/waZuladBXVFwPYMhsq/jOv5Huz05tzQflff4KKvErr9AUGm7Kj5lu
# DATA tB2N0wmNwh9LofPkf+cWihhZwCvouAQbgD+U2JpIMYXa3ipu7eCHYTjelgcpIXW/gmt4MglL2E/A24i3k62f3y3+L0HxF+Vi++PS
# DATA zVv/U/GjG1v5F+K/JMBU7mdI2H0U//bWO+N9nPaxehJ+ZmuHn1ED8S639FxidnQi5BauLNtU86cf46QuxbTm/djDhl71z/o4cLhe
# DATA +LRLtm4qE0kVA9ibSQ+9AfqjEu9+2FbvRNX5GPurt3d2cnmaUkynwbiLqsiPFzycHjDZqa7uULXz/I1yR011FcY0TFTs9PVdHc+f
# DATA lz+SH/SN2PMtN/GhxK13elQsW+rxcLwfJfF4pPaG2/fRdK4f7dG9n32+I1fuj/flSJCd1PlKEBT7VAM++qxR+5xuNrHY0ZXGyhrr
# DATA 5XPZY/2yoxrPeTIJp6HlgAt/xWRdOo1obOdA9orFYuT7Czh6y5HcIjsPT0swfCGZv/C0XJ67tLul9qzItex9y5P103E6m2C4otmF
# DATA FU2VKPzHpz0/ppRJT8E7BrfpNQXP35lPzPLW+vFHVrP96Mf0JE6tnhQzneF29aHnrJhxlpdoeAzHPXUA1bTX2WgbhYxbSjTZoO6N
# DATA z/mh7LEOQdnDT6PkK/XGBs33vhWNZU34L7G2BMeGN1Icrzfi7hOcrsE/VPnoweSQp08FmS93uT7iJAMKDp2ywPTI9C+pILEDi/pe
# DATA RcuDLYM5LdP71CLRbaGfwSWlZ/7wQbNkKKaL6SDA/itprqb326XIjkO+KI4sZbqUHoewXYLk8A0WFoyTQxa2i57ubtGLx0F3hgPl
# DATA ZiRH501T1Z6+OctAKrWPlRXDvaq5Zce76W3ZNc08on3mMbqTOC2BELatwyngyk8+/uDhT95/9z97v5Rv9x7ev/tYf7n/P997t+CV
# DATA YyA9TJicOvq53+PQsldQ93QgkafmFgajfG2Ua2qgRDssfUIFt62qzA1umtlLpnbCOaMVT23XshJLVGDbP8/dhv+2elxL0F3KU/hU
# DATA FPcuPppcL2W5vovDXrAuS/irRgPSIHxaWAy6WFRVgkPX/dUtPG2+8duMOS0vp2l2sZfEk927sLiWhZvqJRqyT3fHMb3noIiZbwSQ
# DATA TCqhUMkVUXJb3KOZgtxZGiBiSVUET2qbV4eiWw2+w0zRAz5+xhdlYOeD/agAZ8F0loQfyxbK3cfJTB281h/F+tytlguybsrXd/IF
# DATA abUYVajaiIKfarKdv32z4UqHOdcDrmyhm3WTbIl5EfvEpnYvKfaFsujn66NV/dgok0wPptOgO7Dj+tFiqS37b9M899dmujqZlzew
# DATA N8/vD3uf+YW6WAZsQ8PuHE+31TdlJ986Rd5ak0yJ1EL2shxA9hLzax9bPoZz3QNF22TsYjTWFFEykvKhYawb5ovHk2zatZ5+4/7P
# DATA 3v/pu++eWHL0JM2Slj2ZlVddF9ebEHDYUTMAjETbqhrzpAg9t55hl+4me+zVf8C/qKKT23CW7+NA/U5zgKIyuilNeu+FVTFWPcMm
# DATA /NIn6DbYYupB/gePpioSuQ6bz21sZ5MZ3FdS8Sl48o0nGMqafQoMp3ef/4EQqwnoL9WIf/ON1z2edqaMBlVdre2wLnk/waAdeIzu
# DATA 8bB7aQwvZdej8SmYkFEzZ4g8Yuf+fczCtt6PsY87q5Fd40Pv8PV+lIzC3hbKiCraxx/DHPiY7Lddb+vjj1FiH3+8JZGW4rumrsQE
# DATA p9hH4WW4/Tbz/1Vq5Vrdn/P/wSvo/H9X8d9f/uDmLE1udqLxTTIdvMnhdBCPq6/88Ic/ZOEO4dVi8UUWxrDGgBVfLFfEk1BDb/UG
# DATA rofajPJ4tjUcUrewxiuIZYpGTX/Dnib9eRCk8A3qrxH0wRLLCXh2f6KsIJqvg9k0GppvPIcw39LhGi9kkNhOyHmn5HSQCAHPXKBG
# DATA lvNYcpRnyZBiLD2njjdd48kfdSy8eOLJ7H0meS1DZjZ6qmGBMvmu3cHBpKY5j9c55HIxpcGWOpZRkvCTUK3/IUNk1plyYen3/nSy
# DATA lwS98GdQO9AvXoyLGZcob2S4wi6ybZobpZm7SLrXJQnRt6lHWbsH5aifkxHf8tbwLIfvsDw2PPPErtAt3kW1taPDk5nFhH2latqP
# DATA XT67Mn2Rd0xxGmaqJ1ActJ7eyk+lKP04PRxhk8y2ZUxyMreO/s+jr72jPxx9dfTvR98c/+r4H49+R5+/Pvqzd/w39OGPR3/yjv/u
# DATA 6OvjL+jaH7zjXx19c/RnuuX7oz/R7fjhV0ffHn95/F/pJ376T/h6y8PkAea8xECNiSo6ctixNIIlvy1fUmX48ST249g293i9dFc7
# DATA SfqrHCEh2RuSz73ZaJLq38IxFjc/DtJuFIlRgn1mGGB3K3qGJo6YXoFnxCzppGa5oyfoMyZmalvK5rZkT1Dsd3MpWmI0YErZHVCR
# DATA bSN8FN3KOSduoLkmopyvDFirP8CUcpenkxvNRZFpO8t+7g9nUJvJ/YQ4YCvytr6H0j6OtRtR3ZGEDBvTwlRSrLZfh+7h/PsBGRA0
# DATA C8tHzkzrP+73rFl7LvvU1P3hG/bU/Y13Ht6/9/gnD/9zPsoLU+lcOuy35Z9bamerZxkFv+TZhWcksWhoJa6vKWfK3DSN7piNucnx
# DATA j6o9y/qxckIZ1zc8UEp1DW6m6gqn9vZrtzIH2Ue5b8WPPisXGv7n1u87r31Y2rmhLnz0WaXQqGKuY7/a6gX++9G31Nr/B7XpX6M/
# DATA +Ddq4H+mFv/d/8/euze3dV15ov03P8Wxk/QBKAB8iJYVyLCbkmibbYniFSk7CYVGgQRIIgIBBAeQxKbR5cekO33jSm5SqVtTXdXd
# DATA k7r3AyiK1VYc2/kK0le4n+Tu9drvA4Dyo6dmOj1jEefss59rr732evxW8uwPuPGf/UVxgK/Uy69UQdj8j0rqmXrygXr2KHn2FEp8
# DATA rP5+qlXVyPlIGdgFyJOCTII6jLTXYwNOC9msoBazppKvbZ5+kiveS8ErNKsuLQGr4XnVFcDOXmoOOkuqrbQen+flV5aDafi/nn0K
# DATA nE4xtUfA6xT/o+Gpkao5QQ6pxv8U3gH/+wVOxhcwX+rnsy+ffak44BOtz4aE95mvES2ljs56JXmtxnpmLF6E36uz1gd68xRW5yk0
# DATA DO0/hm4+mrf7hqMT63/+6+cfARfXi8d6AEtLjRoW0lJjR20d3ghxePDf4AKuxkkvmAgcq45eQ2/3OFXuXa7W7epktk7pkm7rY2NL
# DATA +cIL+Sfr+i54Pv6W3Pu7pfqFYkFtxiWz9yqNfyirp4vFpTdSVugGKnCqEFz1egDcdIQKYzW7Z2kFLu+VSjohL1/zCj/ZW60LJalZ
# DATA K84Yuj/eqrO1iXgwuqNsaCfB72AzP//Nsy9KhgPIbsed/0gVfgQVqWKKMzx7DDyA+YOqXOb6z88/URT2FZAnUK76/WtrVgmsMLaT
# DATA aawrddjJMm57CuHLTo8JdfokzNgLOCF/VltLLXmCg/qMZRvV4+efKKHG7jErm9iYAOiFNrejtzE2R8M6H6c719bXyzp9uDwU4Lqk
# DATA 5pvBibE0/EKblSoCmxEJk1cAvtIMFmhZkSU8RxOHKob/1mohhz6Ul1w4Cw+l39Mwnn8cWbUvn3+s5gTJGI6lT5G2PqF9Gz+/8HS6
# DATA 4rxTZKwm7AlNJFQdkOzzTxIqAQ81JfByY7djq61uooVR/167565vvpFasYu7lem/FVewq/QleOr5x8DZ1cjWtzfLZjPOQRA8okK6
# DATA vr3d2L51e7d2cXll+W7v9sbNrfX31t/daGyvb23caNy5faPGqWpQGH7QvN+uXgRsh17q7MLUfKk609i99c7GFhokcBAkeW9u7W7c
# DATA 3lq/0fjb93YbOxvXbm/sYhG+41awaOO4/bBwEYR1t/67vd3bd3Z2G9u3b/3ox7WVu72b67d/cnV9q3Fj4631az9u3NjceqexsbV+
# DATA 9cbG9RriyaIxhlYLLqq+FBZbIdTHs5YYrjMMXysCGh7eoBZkqUL9uvTKKxdfCZbo34l3GmZDpPn8l0RhioJVXfCSvncXxTQgvSen
# DATA X1TZzTMKlgj3NDGBsLg6RRpUFAUHouoyCAmfK8L5UvX7CfCcL57/moVBfvNI9CkRwY/7a5nxCsYKX3VFjbNJaBDXhae5AeBq7NUd
# DATA +RzM23HTNpqpDzQE3TRjtenenvqqjoB1+F0uyxfX1QYb1AqW/WzQbg8zdce53x4OO+oKn6ZG9UFIkajpEOtsH7yHOwcUPIAYFdov
# DATA Vnhost8GJ2FSeqCQAirfmj9r4NgaztwWtXMTLGVaIKUK4ERW36TujYf7jRo0/eOlsGxwcn2GTFadS4pyFM95QiT/m2e/Q84Kj4DX
# DATA Aiv+FDQPaisoAQQqLUvp579yWLVzHOMiUB/wKc9fFs4Dj3inPQIzeRaZjIxoiSmRN5NUGJ7LCQqNX6Jc8yfoHEgP3qHyJQ8I/lG/
# DATA 2dYPYibsI7XhlXyhDjj4SFUHpxVM2BOzJPF5Z9eN/L7NM/N8FHyu+vIrOje4E8Gw6AT2F4BFcelEEShnJbio9UDB1QFkXV1Q8bHg
# DATA Eq+JuqYViIU439hLr6/vrl9d39mA0yitFyvyrW14KbzTPkUVXSkJlI1ee9qCyisur6IHrVorINM/48oB60Zm+IQEEJDR4KGRpWlB
# DATA lWSpWOdnidNxI1txP+RPfV3WFw+8RVoMEngJrD/yFGebwhPtW4Ur4u0CfMxV0BMItmnbu+E2uYyocp0MJwSUcZ7nAtmVjOFZDMpg
# DATA TWvnt7WlhmdtXxgLKZSUNI3WexhVwSo//54tVjqE1hkYUXF6c3dM7pDQQNjtIMSPmn38U5aGgqzgCXZYek89W6eP5GAqelpL/Iy0
# DATA lpNYY2DABFVcwZ829NtKi5UuXbHh/if9cQ8ttjVQv8mpwuofpgKQqqzhqOc4mHRze50qgIvoW93+frO7uX3/kjz0eq0Gp2lYfS4z
# DATA xtK9fixdCieeKRzgyDlol5WMkHigWMTpEPKy9ch4gYEilXFPCd2FRamITAHgxwVHGu8f1A9jcZt3cU2oSMhXBpldHD+skEl+SIox
# DATA dU/4HHXkT6PHA76gU+CKyFGPkcV+gtc7m0MkpJ94YmnVrAPB2fYyI7FDgmfgxU9o6KCait+A/Jp3OuRwN+sckG7ZnJa7/cKM1u2s
# DATA KkcF9LQ9gbugdXBVkme/o5P3MXb9F/jiTzzWz3hV/4QrgfeXa3DD0OPa2th979btdzx5KTbFkpKjz+Pl3xk6UBa4eBH8Y0lwPCAR
# DATA umGfeJ5gz0JxhsdV0JKRWUL7CERdFYMvSEDP/Qh9YKsLgWfQ2cTh3lorGBG1Q89VLE2sL+QDvPa/TfAeTtfTJ9pYa7t3OiobfYtC
# DATA SeoDvPM+Td7Z+HHt3fUbdzZET6IeeN44eBPQOa7tSwHpKyFOHnPowsUg6lCkapgyjGjPv0Sb2qcobH1FWokP8aJuXa5YN0vaHLh4
# DATA /Smd41KC7qwyGmJ3jmuYe18xPZ06wd41Vf35f/K1D7WlNLXWeuFTbwDq65/ri7d4zaue2XZSiZsw9tOFqb7Pjoc2X75d93XrJgtC
# DATA LkzjZ8ji/kl0RAEfI34MY/qKhq4G9evIrdZsW7CUNbLj5uorl+zRtDpHELFYEy+AChcpGk9aywyMlrB0uB837cEmOzge9+7BJkMx
# DATA uts82W81q2LRw3wLVmxBsZTsp74+nXpUoTjkAtbnjIvfH7cf0l/aVkPRpg0YiDpSjXcuX977/VHouctWsy4lJCGWNyC5FXW24LgM
# DATA IwHzL57RA7BQwwfqJ5xgA2NJ3Hl7Xc3czp2bO4brgpZx4Bi154gCIQ0a1Vw0ncFuzqUAQaIxNnG0niChP6Y9SgSlNoI+rMkUC8Nd
# DATA sscBEQ/kJ+yQT/FCmiTpBerhBXTq93opa3IfEQcatDRm3kt0ivTAtp1SBNzsZUIncBGk9P1i2H+AomDQd9tpoUhqE3R2tqXuXFOJ
# DATA Wodm+RD9W4tJUvBWpwguev0H+YYSMQOgGA/djko0uSsnTOorS4bB44LVxs9/DifIx4prfWGxW0y8WMMZXIrZIdAKHCNFecFkrZ4G
# DATA zAIIXOwc0bH8i99LltCol6Don0aFeeoVa3Q4jShgy9iEKzCwlTrvjUd4hWKtK+BlwZ7Ao7b/UNy5M/2EZRunoJZWNMmi2omo1pY6
# DATA qB/YxVQUYOjhIUbWrlMJOh+ASsvf0Xd693oQka+hXfmL1Asg4nG/VvNJzCIvVLXLYrgrAI9kBegs95UmOGly0tH+CuexGJ8eHBnH
# DATA 4cMneDe0hpI//C2ENIFX3AGah9RdbjkfUkkAX4b8EMNChxhmB7k3IDJgzAxWtCfLiyhyab1YjFdpDdejkKK5r0W/xKNAFAXQgz07
# DATA LISnDejssKN6NkQ3Xa66ThGe0CqyfXHXMAFy3CUeA3fLWQn9TR5VTvnWYom9ziGJBNZEzPOlPxug49jjTCEpGeIw9QxeQqiRPUos
# DATA QqOn8jiGdiutO9xVPiA6AuJAVdDtPuUI9GUId9gYq4skUB7yBx7tzreh/l8+UJkl/zfFuf6ohGJ1VX7+j4aLkapSMXO8KyvpTF1H
# DATA QTQN+DjyQM0hSXR2r1gD5xR0TSDM7fGgdAPFbJbe3M/6XciZZk0Qf6nrXYIHC3MdEkoi73fvYzagrDFsd5ujzv12Y9S3Y6FAEHDK
# DATA okk1DKdyRPqyllamyPO/ZIHY+PuREP8YLKw4s6jIAOs9Xsaf/RHOHbq1PML5fmyZEWWwsmmQWYXH4ewO49H1a1W3uq3jHf9DYKf5
# DATA HXbFdHeuFpgCeu3xaNgEsAiiBNFIKLlW48UAUhDMv7HNAGLgUQ/CeClXUrd52h5mCWRrTZqHI8Aq7/cwSSy6hV5hQBYKNCdEFd2Q
# DATA ttTEHGwMf5MTU76rnDZPuvZRal7Qcwr9KOd+l/teva6HRGzQc5YSrVf3N0LuEkdcTaP6VW7N3ZfWQphroEVZqEvEFZpRe+AhyKuP
# DATA 4R6qo16ItuJPl90YbRyXuY/ChjtLBSEprSZnE6MJEZvDrZ1pJge3F+iM6s8sv86VbB+hRPsUdydItdqVXXR+KG3ANvk5O4p8AWqG
# DATA x9rIwwaKxzn8lixtdH3/FHVupLZEXvzEUUS4njBmsWJ2UQYmkp0X3CNZKotfUazDk8pNOzkXnJsDn2+xIxw7mXwvYeRawl5iMKFO
# DATA r4zOrnp6Gb9L3efvE1BSv9vSyExITgv+mTrL5zp6SQGhHtUO/w0Uys8/kg6Ug7slRdiLPCGtsse02b88o1hIJi8ibu6les7BnmY4
# DATA J4+KWnNKgawJsqFpzPWKMMgCWh5B/4iLF+efDefYyZ8LUTVYvFRkIq8HpmntNJ/Lfkhygse22GSUhI5yLZS0qnNEIAoZa3Eb/U0Q
# DATA qsIR8/KVpTMcNXKnTHspC9q03ltuy/4gpHxUmrFfxq+9UgJvKtQSvfHn6zyX4HCQc9x83bXUPUftBuZYUmcDYnW3CxKTYQVrdg2e
# DATA AJuQtPpY1g5U/3Adsq1NZ3iCHbIwV0oaAJgg6p0JTgoUy9FJ/U6N+A9o+iCj0SNxU01C8elxqI2SpJ8u8erNPcclACM7yUor5AJB
# DATA +rk3AXt3mG+jpOO+jhOPKYMzJVs77HJUmbJthm9dg6XDFBApoT34SZvAtAkqe3xi64TsmUTWanXNNcZLwVmsc/4es88PgBg21cwd
# DATA K1HT1GN3ctg5aaIPdb6AZXWPi3s3RKmELYnT6fcFZh3wC5u9ZMzKGTlukem6XgLC0O0+U34ef7ndcCjajPTMHlx+gBSQnRuoxP+Y
# DATA u9dLjowc1z3ftYKFrB2ig/wvov+d2xDppk37ogXfunV9o7Gzu767oeNhNjd2cMcyE0UIIDhhuTNmXKhkz2OuM5aHcjO56X5ToyUO
# DATA OJ+YQ5EeHPu0tlH55ksrLIzDZU46GQBSu0FgpOrL4gZG/l5fSDy+wbFKMJGePYZ7JcAvOvjOtoOEU0dq/ejgazgDf50s91999VVz
# DATA I9azbAeB324TUgSjA7fvd/rjLNm8uf7WRikZZ5T8APwBH7StlNC9Eev+1GYZAOKlVSOh2SU/G/dHzeSniiTgYMeFfICx38O2mtpx
# DATA GyPMO4hMBBm6WnyLxbCM8cCElHPsIbGAkrfz0J2w7u5RuZ+5JW3toDuZeJOe/wYoByl+pRaTe5a3QFiuFNzZtA9tt9lrEHgk6JUb
# DATA LM0XaGglmmWI6z847mCqd8uVk3FFmCG0akDSojjgH5aKskFV4gtbrUC3B5NPQjyodISr2oZABRaredABLDZc0wfNYcvoE8D2m68S
# DATA JrU6BpvwcKaVCwSP36ILhq3w+TNZRylS7JEYeROU0p6oy+fH5BnjaYnQT8Sox3+V41PoWXx5sgXtyoGJi6HBKT5MCZ2BCWfvA/TV
# DATA +3e/H4F/s73nHecSUi1Cv54++4ys2KCEUhI1GpI+jkwFX1jg4o0RJLGh3ac4ZMzprpeKH+aOnt+74495qV8ovFG9W6E/i2crJQr2
# DATA o6/nGbS4f5Iz0odovogPlcxM4fiEthpmoC65BWMNvmB/Q/eICCfF/+4FZ8evpjivQZHMPPZMuU6/Eemb8UnQaY0M+Owxkyieq6Td
# DATA Ang0qHv8oIDAX45bekUdSRAHtbdcTxaTteJedc0T06DiYFZgT9CbqeP7PXtFwDX7EZIwLzfHG+mRgd7oU9Im8cDB92OaBfIK6e2B
# DATA U/yH5hiKpH5Om8nxQv6UFftPKf6cNL5CWQbvOXO3j/2GC6sjsOF94JJh5BvJpOMX5efr9heloAVjTfLp1Cpk+axgfgG7h8zJnDoZ
# DATA f0i9c107e6d+K+wsOWUHmKBg1+YOEHvGH0K7ajrd8NpHw5+aGqeQvrn6n/ob1585MynnGKTd12Ap/Kp8BExaUGsx5m+Lv9VuRzAN
# DATA 8kzPgFUoHJLlhxxQaaylc/ilON4NFKv9j6hD/JBiMz3+FBhwnuh4Qp9zUf4E6C8m4XC2HzzZIfEK4IjdzeO8JNs3S2LktKZkIiqo
# DATA BTT07jaa1E5PZsvfLfY7Xal6rnuZM8vBfP6bmh+aAu39+mcMLPxDEMnxFbKkj/G/Hz17zDLOeedyMECvij1KaMK+6bWa6Tk67gU2
# DATA b6YIJ5Id6I8qNOTHvzVhWxSXS238TTA3/0MN6Q8YXPno+a+e/zMzb5kfCWmIat3+QnEtqgKWGsB1+iOk2I9VTU9CMepzHfPCeC61
# DATA nKgxdrHf3uaAQQtAlgWFi6uif6aqUO28tvzDSzIrB8dEN9gO+deR3e0uoqfdRa8VhEyth7PyW2fEOUQR1WY/xZMPnRHxgTWGPL09
# DATA u1hMUc5r3XfuJYq9I524uqjrRj0KS0DKSNTcr9qcj13SZugs/9WK0vVFbJmXL5nOPgj0mAHrElWm1m0J+j+PnZ47w8eOlYLbUdbe
# DATA ACffbUSMLBa19R/lMxDFwGm6AhhH99qnWWFvkevhJur2J5X2wxGoguezL4svn61+96wX+iINtVcDd7O5jetzHByh6jgeaKd7Knrv
# DATA MzKNoBsqWf/AI4yU+dWIr1vQee2hLCwf0rnjRDj257Si+EBq5kbSMVHYjX/JBgqlv4qxs0W7Grn+tWZfUGn6VJBICWfanVXxVyY5
# DATA HYuT0nKKBz6N2LjdzwXwfB7LDy6oBtTNtfEiVkt0kae4wOjO4irZVl/bwcV4xtBgnZU02hzbUytO+e7uo0aL3+5OMDtAyVAQ1GJ8
# DATA wPPmy/E4+7b2heIf7IoJ+HKVVrs9gD9YUWV5ChqBCk72tCRcnqPFQTv8Ui14mOeKk+Mf8Gtxkv8SzWpwuCMyRQKxUmrO/gjOOBgu
# DATA akLEn38sR7uNkWAJgxEnmLjUJpu/JrOyZzZ4HcduQCviW4uLB0ExbgCKLap8oc0Seae9I27n0Ur78LCNCkLV+YJoDmexq3lGpCue
# DATA NqZ8fQ/8+JOMB+U87cOau/rmbvEob7gITA1rq7tHA6TnTpx1GIJEhYIYJKdeGGshEr3vMnQu7iECONNJRah3nb6x2lR4LcCo2aZQ
# DATA 2tQm4DKkG0zjwaa1Gl5Rcpn3Oa4dqCL5giJSgNhMtBNHqnHITQzUw4IKDvedMCyXvqK+VMO2ov8OCKBAvN6KcoYMiSjlxfgbXIy9
# DATA 5XplqNGK8El5ReMXVaWMvRxWW4iGpH6NjoYEFi5//4whz1sdfKzWFAD/AfdbySgP0VGu2WrhEyWQtQ8799KodfLZv+fuXNjsv1DU
# DATA D4LpP2GsllqfzykKVDRUCe2gp7BRcItgABqUQzCtD9CD8lf2nelja2F4HfZ4AiGSC//yC1QG/UEh3R93upAsA40Ils1n97iTMQsB
# DATA nBAwIfQRrg5cnDABgHbxgNfDQb9LJm44MUVWsOobQs7Tdg/og8CH2QYFuQN6qkeAuNmF4B1VYQ+TG+j4MYAkVgdiJRyhDeMP4zxb
# DATA XIwFPPrSl0kyAWeodV2q8uVNgxKmoN9Pv/99iU3WJGqfMjGua58fWtsBnbLMUnYXw4rxJl+P9ZnTfaiyBHNl18NOpvSZGzeLinE6
# DATA KSx1OIkF0rvYdwtuQL0lJ4edDkPlhXPlHr1RxpA/UVPWMjwjnML/k50Qeu1y51ybHIfIHaXk5tbO7vrWtY3G7o+3N2BZgZupHYKM
# DATA jLB4+wSof3Dcbo277WE68bWG9L/Cfr/fnUF6zIVJEnbmU/hzrZbkVaF5UDGnA9bMq/lg3Si0pH5Zm5B2IbUlhF90DlueJ9AjfIPH
# DATA rhZyTGztIzLgfYY4dU+UWPqUw4Md76nphy+h2OK2uJCkV0LbSKh1dYJHyUymnWkf55tRtf+6tga7LlohP6ha2W1QpoxwF4+Gu/rI
# DATA dojY6M8s+RK+cLRl8GBuVdlswfOrmOD5JI5Jg2bmzzlGf4ZwPYV1z2L/Mxg5XcUOuk26izktTmUNakb1dzZDx1yw/CK2h15CIJy4
# DATA 2DJ9jh47NxYBM7SiKELbvDHt/hHWJgJccUUI/Au+FaNx8EuResDyR8B856R4j+rP3GmsJshvYof/xA2kcC/HeMu1sUx1/BQwupo4
# DATA cITmvRppw0uJrRut7eFlnlR/xbp+aVSINbuAlV0qIndbPsgIbwdg6oHh0f5yF4rdUaVYNsgtuE2MnpBOjL4zpy5/y+d8sa2le+/e
# DATA aXo/0/yOUb+XJ2X999qkvKZ/XFQvLv+wuV93nsjfK+QnpxuLsxlC9ZgK8xkGRjxKznc+PEH2/4gcI/4J8FDEFcDAp38SREjs5SwA
# DATA CMJmWHboxJn2lKgmKxC9o9X/Vd9vFGUJ8txkjRPToJvNRQd0ghOU/lt9TJo1VEwZVRZlgQIHr6roWSTaVz2hUUG3eNdCKf6z5J7V
# DATA O8bzKroVJuKLNVOLj5pwgdLVkCj4MwjqyLWEWEC8eNGM+eLbbpuE/nh5skt/XJr8hB3070psM3YLLrkeALhOuBPqsyPhrBKW5QdM
# DATA +1Ff8WCvnKfwLcW/Bs2bmNYAVtl03INEco90B+zoKzhRtD4DHcFihpyqOg/U3fkPeDzI8YH7ivWvBpO6XLYDfEIoodwVNt0HXxk7
# DATA f1IWUUi7Ex8EEGYG5+M+pxKJOQyCI6EhSfjleTshMAlGcOp3mQ+5NqcnXm6kzF/AeQesbLlHblyLHZocoZOzwoEKVkkaSj3vk8BX
# DATA 2jU26Bk5CAAqWYntteIqs3NfRgBY55mgryiABp26WFj63NZsTzFb207qe4vUMcN1lcywaAbLXBftSmH4peW3HkQf6Qyr+YYEEz8R
# DATA YgDBjuAqZgTguNhA4s/gWUbI04FdJNnMT7Z/mFQ5g//IeQMe0zk8ZQHYX+wxFDdMwglCRIh6HdB90hnlbUk2fzRckKHpu/hFt8Q8
# DATA sRZYhxdlIQbnSOBaQEDVueNm46RDluogWjMM8qBOWZZ+fGAs/fRzftY0y7z/WHMvgprLpQ4HVce4peNEuQ7ps23ouf7jdsKd0HXc
# DATA lDDE5bEoHW0uMa9EbI78g2IfU6mN6Y1u4RR52hfd60mzpyTwVgJqDys3HDvtUyPguggJy+FfcSO3XcNjkvucHoPnQiYXquFfSoCA
# DATA BO3ncWKzBG16dB4M8+9w57LGXQDLWOh2bbHmgBLqzLG1WkyUXM8fo5ctYaiRp/EUljl91mhX6fsJVBA641mCSUx6D/Js2y53vpuZ
# DATA dyQ7zrZ1R/CVWs7hnQ5Ayehgz7gQcInzNXiz6STWiZiNmZbN0RHBZ/VvycARAcxXfAf30iTG+cQBQDDh21B9uwGBXA1iTxLIVeBg
# DATA F2BW5wq9d5HG6B8HZqxn4MOhDb0hpD0XP4U3gx+1RzI39YYC8LkaE2OaB5EUbnkqM0uClVJG7q4b8CSR1ecP2gyi6XQIHc5KJGbT
# DATA B6DyEYLM0GehBFmgA99mh4Mg0zlYZ4BIpG5UrmTi8tFg0JHhTt2esqy263E9T7gKCXG+0NH/XcNG82mGwkZZud1Eeui2wVLcf9CD
# DATA DI295iA77o9C47eN+Zze73fHJ3LcGHeq0ekAVEzpfqfXQnMZdbpqpxcEQz+tUzVxh8ZC2wuFrhO/NZ+CRPhCurjE9bStuuxHO+Bi
# DATA OaTJqkeitkaO/pi4bCMaBu9dE/0gdRrePIzG7OSixaU1mujX1ZT7HYnhCtKvonVkCSYp/ZJjsDGmpJ8SBCW+lMN2t93M2pyXurow
# DATA 0/HSA5d9PVlbDjSN+m7dU4Q77Bxoh1C1h/v325Q2UhE2Ke65C74b6PTMMz+cmMg1/Kmj17jNYn6vJN6MIsx0bBl/6ESXubov+OxC
# DATA UlguFZPFpLCWlPnip54Xg4lGW0rBDq6cGcPph20GQ0jZ06VkBqMdU8RPJvA0WnBdlRxs51HzCBFJuY7K0AJ3rqaecCsYyuDRRMms
# DATA 1OfVEEiZKwu6aqhh9jou5CKmpgW0PnNdF1RdRVVFuXA/eFx8A1+8UW2etC6tvd8cnlxaUw/xnDjyQJnM7AjyqAbJN/qikoW1Grz0
# DATA 1388ICDigqncTX5rntup/wrp0fHBsNLpmzxSS+TVpX+FtMbHRoMB1I03pxandNNmoIhSUfMJNuYjYSBxcTF0t0MXtgXPZ+bMeJxp
# DATA HzT8ozwY9h+eej/LdKkf2g5qlntb6OpmPNzI6W0SUKNBE5vbqwYcLDAadT5HjLgDjuXZ7mDKYN1R1w00fLuIrdP8O4LxEVQIWIqN
# DATA pMTqctGbCxlpKQpe4b+uWcwuFulDrGOlaG+jJb2m4JxSEo3TS6dvE3vT2FdqGjFk6IA/6A5KmV14EnmbNDNw0PNPwMyHNCBJycRO
# DATA 828+niygg6xWKDo5phsWHG140rr12pk6GiZ9d/53un05qg36h5a4rQ4wkogRe61GApSR84RyT3eA10oE3RM9z0aRq3sSeWdPYRyy
# DATA gY+E4T0GxzB+/Q/Lhl55lvyMVdYWpSoCr3AHVRj2IpUL7VA2hfl+gP7YRVy369IGMOvqFExM7ENdKtWCieHmg06vB/boKEkxazfT
# DATA 6jB2PuDnOLlyBslxXnsx/AbpWX2e0eo388XF2mvsx8Krgrnx8PCZgB3bb3KhlQv5sb22e4g8LcoRyMNQ1xXCDA8qdnrdmX2iZyb0
# DATA gcZuH/GTUIuHLVcjDutzEUxuq8UIFZ2fkqZvGeqfH2U1J+Ucki8b8WsnY6Kl0WyBJ3g3khGPswL6rrbGg5Y+pMI34n65LC3ZUoQa
# DATA a4XcESqix8mcOPC415FYb4u+e2ikPlM2EtKUCGVIhLhHHfEEZt6S+oR5xlRQdWdlk0hDneUsYVW565NQKJ0jvmIuco11wJnYc9Gl
# DATA 1xfsfRe3sb0G/eERJiox9FWhW5gL6jKd1HXdnchFXV4WQ7d3f4uca3tQyGfJoJUdKwLqldhNXi7lwPyciSmEwygFUkgoTKUOOgpl
# DATA xGEQlCfoUvlIyX2khHAFxEI4qFIg2YTCmtue652AMfufY4soS+VFvdIMeXShPQ1maVT43wCnS2rwfV7l+es8ljBIatjsqBW5Q82+
# DATA S60iljK7vrp4MraPtmSzh6xt/0yOxtW4q+sj/I6mQH1YYuckNC7JW6IUz91AIIxtA7D2MvJtLBqBSU9XyRhqYiqpqdaYmHFk6Rs3
# DATA jcBimW+1LhiYql2ldNGUVELnsYN3fT5431xM+aaETca1plHUAvaAJ9iCbwGVIPUcOM6FvkCdC7A8on4WGi+o2y147j2Bl8NMWH1w
# DATA zwliWJ//CiLZJJm8wZilNxYKkzH4MLHloSl4jiXVc2GS2qZ0TO7ybfppIgojwDQQqLdEylFSOzIXjDN1Xu2fJu3msNtBGYt5cUZn
# DATA dLvZsqrrI9rjQN3hmyNGcOyoyjsnbfXVCUjH2XGz1X/g4s1WQpgF12906T/Ta3Rphs+o7vP/lC6jc9CcHgA7jZpF8HxGl2Ieoy4s
# DATA qQ1Nwi6k7m6oSICwW1c1ArvrwhvE3LSqAXSDuVbYG4l9kvs9dQfr+hkeYqThaAvkQ7c/pr78HtHyh/UnxIARxRsOag9SiZxWrFwH
# DATA EpeimTLEo3BA7n9oP0ErqPorJ1fbr+nZ+ahCj++FkV6YoUcM3a7AEEkMZfkuTgF4kAPRdYoNnsIZEiIJ2UXtx6awqSBW63cJHMHH
# DATA OxyCwgDzAcRczQANxXVDiqI6Eel8ZWHi5MOnTAGCcCMAn7gD8GW/ahQewhHvop4QyKGnlvDwRKwLu7nBhU3FEr35jUXLeM0VzE7L
# DATA U0pbsBVUU0xWNn31Ez/HMJq0Z9Qi7jzBaHqh/CFTcod4HuXixDeFpV1B8C/KG6fOv8/U0z9J/NxXJIN5QJr4yCDlOkk/fI/hXqv9
# DATA sKQlwTaaBpsaoXombE4sG87ryeVFyIGD/5niGG5go9Dl++nzX0gO2D/QWNUDN30tuuCA8SaCkiO5M6puL0uJpKOoJmHKDM5QB5MA
# DATA JU/IorLcv7S8PMkduIfaofokKlFE8famxAb1LiXkTVELHPCLET/iaE6NkqSnyk81YUe84JJr/YaqyXaaEDKd7ZpyyK4nXOFkmiuF
# DATA LYk25FwygHR0LlmZQBE/XYm7NSdVxkyeJw5cMbMGelFaloCqYQqWkaIac+QDe6mOn+O/iBScaLEcb0ojy29olqxuZyDNZwnwmgTS
# DATA e53KrZTQyJtDUDZizlRCc8dKrbpg9ivJBiYQA2FBfZYh6Dt6gnVbDGk9AMAObIQlCvToHlXiMOuhvDXLu93eC3E5lBG0v5Ebl3/b
# DATA 8mVVQfwvBiVCqP/5/fO1LPWN+SfFvf6tEGNO/7WB/yhqc9KmO4mv7B0Wr9bddxYjAKWY3MN7Iw9EyBJbbJgC1GgQjIE7LFJptToZ
# DATA 3n4LFra9pdvUDIUx7UXaBWK20ey1vSBuXrBiuiI2BJYnZ5sQtMrfcwM9l+VB8yRqlJUrXCY44v8lzBCOEKeeFzqHivH8o0e+A6nt
# DATA hUGpU/Ejk9g+T17+lda6YFcbsJcK/INPgP7wHoFWu8rC+c0nFa4CNHwGwSmqEeSSjjpQd4B7kC6lOb78Vtb7BGeOYJWe5ib5ypWY
# DATA ymVzzOUgoMKDujZz8wOWS+ecFzoMGnRm+tBWJb9h2FoFmYylZGBNoZ9pHLmvo7KkxxYQNQWuFH1F3/Rk5c4UIzSvAzb7JLFUgLOn
# DATA OKJKIVyNOCTvfLmcebw5cBmyFfVrGx03rlMSRVA4WLtqSDlh6roSyOc2tDFcOj/A/fxLK3CGE0B42lDUTTo9phYa72z8OLIN/p94
# DATA w09I1Qy5balJdY2063E0A2cIFXTSZFgAWwyyuHYgBzJlkn8y8dCqsBUPJsBzU2bMW8cVoJpopztzGSS3ZPp7L91sKSHMrdi5f1fV
# DATA lqE66ij1j4ZNCylgrz6Zkv266p7xcLPvbPeHFHYzUH8YACZ0f9++dRsholfV/1LXzxUr4JNQdaGXqX12op2l4kciO7I6LlIlF9yA
# DATA EEbSVHsiRgFKbHHza52fDMp+rlPQ8jdhdJR8fxMPiT2Ml5oL0jAXPJ2ZUepdOkgc1j6MMairmDcMX4vB+xB+nhUO5pvJ4uyJq7rM
# DATA rxgH+UJ/DNcPY5IPzDYVjq0QY6cE7xWQGzwOxOXCFAfQ4osCb3m8OAJiGPYu9sU0VMPAXelFkSqjOGjfEk7lf5b/74vCjupMLa6A
# DATA G+bcJn3s5+BhoM2Ev3n2u1LCGGtRtacD7/QtQAey7zJudNdpKw9/z1y5+tqzMmd/FbD2OfH6LBdw7bpedsqbx9aX1l1Vfa/5HSL9
# DATA uVxwOqSfW3YhhyJEWifoPdNi9QX23Ezc0nPs8vgZT2jeUwnauKdMEUkdfcOwP1LyDrknqr1UlSr21A+KS1Z/kGXVEsDwHsEv+INJ
# DATA ft17lsyBrBDu3CCT8Kf5ckkxpqYJYasjeyKKgTkzQHkPTdwVKwqmlgKHA1+YGqgLzJhyStajDdrATJHaQWulFwJvZGRqP8SNOyJe
# DATA Gu90/RwDFDMdLJwMiLwveJ1LxhlD90cOYVlxFnhUxTH9FFpp+ctzzv3Z4qJ6VEoWF3UNkzBzesnZjg5Qlvq6oPo66KI7/7E6KUiy
# DATA gL8aQG+uRJoZYVTKggm4DzurIE/EyJllDyivOIHsZRWCKDtuPyxcXC0u6NwHKF7FYPm8LxSJb9/a2X3r9sZOY3t9Z+e9W7evo4Kf
# DATA GvKCJKzCd3Y2bmOshHUo6pfXr7qv/Fo8DMFD6zitLi3Jj+qZdGPyN4ZJt/arr6xdXF3Kr/3N27e2dhsbW9cb12/dXN+EKP30eDQa
# DATA ZKpuIDWzIun2+tbGDVNMv/Gr3LlztbF95+qNzWumsCNIjYfdrOCsqll52Fp7l6twmXr7vc3rqmfrV29sqN5tvLl+5wYsjZIyxu1w
# DATA IDc3dm9vXjNz3WyddNCXRF7AikVXdnWtGNT23sbVt2/deocJovH2xvp1rDZKF6yQVxsVAhSZmLWk7G5RIrhQSB40R6P2sIdxdn8H
# DATA Ez9sVxCFug07v4jBcbXK4vdTV26T9JD8eQl7AUbHyk2PjXL34JPxvinP+fsa1SRgMFLZYbd5lNWwyin5a7H+CzXEUVU1hOzqAr6y
# DATA mQN8wswAgR6AF9AEY2Dnflsc8OiHXIr5lRvniPmPBOXVT4kEv19O7w7v9gDe9eVzufUhLqnWa1wBLx7OBsW6T3PCchIpG3kd8Njh
# DATA DzIlsuTmmG4GzVMwXKvBgbWhAn+D8SprX1qr7F9aY2OaTIvAPlFAkeMoHUn+xnXjSXuv6KLk8Lu9eywwsCNW81p7ONpun8DO+emD
# DATA 0fZ4X/HtdxiRXvXEeg0/1Rv45QPmktfru7Du5Ozq2BYK5kUp2T0d0J/BqtgT+ylo9tjPETGKJcXiI0wgQJo/AyD3CBBjABn2Q3Qo
# DATA /ujZU9RJk3oWkZqexvOaMmUevqwFm9oZ0dvkbs90qJaeMXCroumXmYYfNDsjQixBBlqQELXOSbs/HtVWl01IsRUpgLHuih3cRPQR
# DATA CiFUq9dqdpUkmUaBRcKTj/VHUNd1fCIYD+7OsYpBk6RrYp8eta6dQzii21MSdmFovSqZLYFR7eBYtVQZqPXXSi5TSwAoAUS3nLzm
# DATA lPFM9a/VkpWLK8uvrkY36B/QqQC8CB7B3c9NdBNd6UfJ27u72ztlA6OjA956nPLe7o0xArMuq908ZJYpSXjL8L+rG29tbiXXNm7v
# DATA br65eW19dwOfVhbfwH/VWRq8S63c2qq6HYd5QTPBgH8fDicYDF9ZLW256HMfDuR+4GUJz7JuZXvjZgOG3Rj11bF6G/8uQCfU0Vss
# DATA ViRZuJkoPDjgS0ry3WCUiwa/LBw00YoGNwRrOotODRWG38HDJHmf6nt34/bmmz9u/OiV5R+q41lN2fqNxrW3lcTgfKnO8c7J+MRK
# DATA xQvf7t7YYXd6+PP+SmOVPcWbLUVzQMSw8SonfTXF4PtWgDOU9yKZnI7BlBIUek1XYWGpBMhqndFxkoF2bSSTonrbAxO7uiEU0pXV
# DATA VyvL6v9WUn2SGUagxlNYhbD0h4XKSkk3V/a7Aolym5nipQ8iacGhAzJBD4bNQYN6U1ClSS3XHjaET9S0cAX1KcY1HuYJ+ookfYqh
# DATA 4sCsBu32EIllX93Sh2ot+8MTPog01QADE/Kr5l6rDMg9YSx+AP5xDtoV2BchGuSfJD2JDVypFrxMGx7h6z9Mizm3Fup61gZ22i0c
# DATA pm9t7CoWBvtoaaWyAgLB22pqqsmZzNAEnl3TS6lu1l1wFwDJQf1/yN+Gx3GxmDd7q8vLwMY6qPuh5hX7vF94ZWVV9HTFvZU60Nna
# DATA 8nL+DFns3j45b+3wsWkfoZvgMOSfoXIFMkQM5JV12+1BocK3H1oGl63YiYx5DT5AjOk/Jxb65ZeUFPP5J1dEqUahO59InmVc01KU
# DATA LWPi9P+gpDJgK0Xhr0yqRrHm4y/Og1cwd5CsA74F6tiyTfYzL4Iow6i3aYpnr9Shw67x8n6YUgICgANKlnH3LqtLFR6b8kVxAqzn
# DATA yt2eVXSvWq3nlnPE3cM0TWlnJmdnC1YV417nYXXpfnO4pPbdklZiLw3HvSWciApsbqgyQZVrA+7a/YN+98rCGQ1uIpd0tetxKgxB
# DATA XyErSdZt2Ed8pLVR1zvVo182QLDP+Xow7NxXr91vpa9Zgmy6ssr/XqQiICqtJv3elQVrCHi7ypL+4eEVtoGoY3JpnA2XFFMatmlS
# DATA lo5HJ1163xyP+ug1Zz5pw3ZoINDk2vJasqT+U7E+aLXU5a3ZUkvxo/I1OpnLIImWb9GFVNFk1uscKqm6+6B5mgVf3QbAlGF7WN7u
# DATA q+k/Bcm6czBiT77yg+N2r3ww7GcZP3Gq6fZJEZL83T8kSw9hAsBbZkmIAo++bgeC9dQR0djvt05JOlq+ot8fDQcHDRJX6FBJLi4v
# DATA Z957YHvT3gN3wL/UVX8aCWIXkQSpgsnEHYYaxd27lcIbLz1od7tlxHVYKqrRqJOtdwp+zleCT2CwcKqSV0Ly/fGwg/9ZSmpqobC8
# DATA +n9qvzA7OBy2s+NCzJ2npK2/Ys/Up16qD99aqoa/nJZo+9S0fQOFdeIZWNrXNOVYQ73HyI9UCyvYAmq1eu1RAxUQFBDHLZmncGjy
# DATA Q2Qa6KmpmEP3EIJwuqn9jqpfW7soTzu9/f5YLS29uAxvbLAiu05R/BWcuu0LRvwuDBiej9m8z4L2B+Tk/uyLxBVA8VqcFhdmqcDd
# DATA ftXca47OeWmtSNAxyouARxBFuH2igykikrEJi/sU41YZQPQb6a7pmtYf7uEJEIuQY32Fv6SRxQzDkSCUjpqgWLqLeSlUUIL6ZbK+
# DATA vVly1gcwqtmd5FHyo2Hz1Fylv+QIOsmpAqe55RPSOfRpOQJ2kwPt/lsMdIJ4wy11X16/flNdl9yEdJ+y/PAx4GHDnf4jO57qU1pp
# DATA E8UQQ3vXLmJBgGmAi5vndZavV+r2j47IH+0sbaljDd1CUtDQlDmNbtofiAfIWaoYdRl4NBS6uIzaEXiERdWjV1JmgBB32xfAHwSQ
# DATA gtfjnmKCWTkb9SFdC3zMzUMAPv0VKCh1hP6Za/jWXsZsl23ZDjWToJpxt3PSGVE9vT739yzN+ofQs5XltcuvvHpJdUgduy3zYDKZ
# DATA zOcn1RwMJHkZDZ25tCStkaR95MpqllRSJRfrpZiEDMuV1fYOzT2rKlqaKnL6+GcMyljbYxt0me5MdO7BSWdM0+TbmlWX1CovqVEs
# DATA 8YOcmlttMDBmjX6vZptOW/s4m0qMbaHtCMGVGItBCRLd0fFpOnGsqmQSn/3RJNoNeo3YiKofI0Vh4IOUXrt5vbzz9sYNzI91ANmv
# DATA yofZDope6uiHQ7kLhyZM3coS1YGe55hkUc0J9GBlGa0WLE4gUWdkEFaSD/o6XaKDZThqDNRVv9+ivZDZ5uGQpwRGW1BBDtQ7yimz
# DATA l2oGktZjKZYipKXtI9WVy5W19IWJjK6QxycofNVSdYE72afaxAKm5nj3JzDMO7vXYB0NfUkPjUhl+UBMaW6eBRwcNToZyH6nSflO
# DATA 8v3vnzlmpklSbjkPr1+dBIt5cdZari5P7LANRZM5c007hjdO9YflZnfQ6QF7nHev5U0GtKPOG+t7vBpAN8vlTG0VzPWGv8i6DyDz
# DATA pJWmp4r/nrRP1DqXByii07u22ka4qbAMSL3UL/jtdY3/QcHXL64oHJn8q6++Sq+AI8Ffy7kDyl9a4xRTVnI/1pfN0R/IT/o1V9by
# DATA nbPYliqlptRhS8jIrMRIIcPCf50gpVB0ruYn8iWRL98qmP8l3uRFv+2/CDw0Ip/WRAwAb5LgNTjDXF4uJUrKnuT6IrEANj1nl23C
# DATA iMldlMtOVCdkpXBkpqck5qZRF5Zsz/bNCVzd6vH9G65RSL0kadQIBl59uyeyB9JertNdFEcwcmxN4c7298KpQZo7pOgX531s38XE
# DATA hGCFQWJYiW7b+KH+Yofz9N1PcI5q34d2bZbTDtsQv/QyH9lmPND3JWQAvWaXz+6Xi5XRsbo8DGuvs+8WxAqOCsNK/94by9WVYrFy
# DATA gOFQhaJXQr3K418Ol3llFpdZWY0IA6uuMMAnhECsQdSThwqhk7IZBmm4tRbI3MhIuOBTJBje8as5e4Xe5uwKeltdNaeZe+i/dev6
# DATA xtU7b8GYTsbdUQfUN6ODQW0ZhAAmuvTycvUyKATg5l6l27v8uTRuDaZJAXGhNdge16CXFNYAxvXqkqKRJez6kn5VHfZ1CvEyzGd1
# DATA Cf5rnpGKtbrkJp3xGpfoszOrIgxT86rxQ9e0v/gZRfkbV/3EDneTP2GZGTe9Kk1PLBX4aNjEq7ZevciCkzJ3zwiL7FNubeAI0oVT
# DATA CHfj3FcYJcqCNyKrcODAenGRk0XfmiP2aq2OuYjzGEtTiEPJDUIWUa1eWkqCb9RdM3M+6h8tZeMBrA66f8a6HDJtsBovwTyI4BXr
# DATA BnO8nK8P+sO29iuOfY6Yyk6pelyqQUUSrGGMjupuPE9E84THANkUrPfF8NIidFsXX9NgZGg2z1+SUTeDvZp3tlsmkjymhW+rK5XV
# DATA y4ZvxYhz4XxchgwQsL9tNkMaeHhaaS2xPRgLIcOZztlecGrOW+vsHXDOCh88eCAVxkwR0EePfVosy17AF+WPk28igsqoyWbHUAVB
# DATA VCF5RPB2QErzwqzgl1+1H0aFUTGRGCqaRJaS2Lulam9Xv2JUMeiC2jqYo6wiZpqyZ/zDU5qLh6dhdyk2q5qIPjfFjCBWTxHHQ2eC
# DATA mlNFxl42tlx6ZwjStR9+MtVr8lwXLzug/CxMkFxNyDzhvqGxB+LztE2UkyyY6BASBVfgP2uFYnFSDHvoA90IZ516z4nBWDnjtd2t
# DATA aq6WnzTy4hhVI52wo7MvUpFN0tl7pRxNfjHmBG0H6QFRKP7hBIsIdgymwyuB5az/wDclsb2m320Bd3/gBQ1wZhFHYC1gdUXbHxXE
# DATA a1WDE6KFqgU7pQH4Q8Ou+Nv3dhuOw3KK+b2ub9Jf6KVr+9nC3+I+C7DKpkkvH7oqR6l85Ffgi1yKORPDQxPUoH45MQhupEwYW6SG
# DATA TVESL9Vg/sg1sn1azL3b/3edE/Tpsz9zFBEm2sZgWkizHQkaev5rAiqAmimyUZEGYf2Qv+2B2gSKTtqtwl7hhBwBwfwMIRD8c4eS
# DATA /pgH19WlsdPD3WA9vf1eyoHZmA2KYwRvYnOclLUoFNOgXiDhNHSP6A9DOvzbohrwM1J3eohCk8xFsIPR6tLPKkxr3B9I/Hbtzs5u
# DATA 4/atW7giqELXJ6/qrZVFaoniblXlCDuM2i6DzCGvBGTWQg/D/rBx04yMLVT0FuI89TjN8ppnnNmmwB9Q9d9Lbkm2ytHxsN02GIll
# DATA SGOEKaDwAOYWT5qnyX4bXAParUqygXAqEsfEFWJJwGAbNPc73c7olC6JJXFRRnsjCWqKVaAeDPgsgjqM+swpOplAKxqoBFqjrxsV
# DATA GsVPkKmWxqCPEUYzNVgcaBKGDiuBR6OZ+mKwL3VJazWlAoi2AWsj0p55erEueLxwXkXiqvwwPbspyAfD9BNPLTZnfZSbS2yQVPWK
# DATA JwYO290mw6FRcbMDKvKuMerThpIIdxt3AQ51/8NO1pjr2zBxsg4e4F7B2oKxWR5UKDkSSCur+PKF0rq5tYFrKdflPF7B5B/xFdiT
# DATA haqHaxHuYvyl6daiImL0AR+IsXcEX/iEjNFfoBI3ZOyRvJvquk7b9ybr8UAyuKqIFXCW4Pe15mC91eK/rg/7Ayw07NxXYjWYaOvO
# DATA Seyd+yaCEB05wrp8FPTmwD5oJIywmpyhg25zUFSykLrUI/HZqb2urasDn8O+m4jRUfCC+MFZMmA0OlpVnTVuPCEsAvSGDhzuF/xj
# DATA Dhv8ZR01kZhPGTHzSamopqtP3leShVGYTObnBHYTOJX5bZTP3YbOzDlz7hSFWpw8v2DU+SOUT0wFVQ0oDn6V8V0GN0msN825Jlfx
# DATA Kg3KXr4xpxFVDkSNWSqfaMFQaYMYeNbv0sJEggMh6arJ/hpDsvCTv87vECLA4PLexQU31fj1TEMFd3GBorEKMzHCff8k1koWzgml
# DATA UZwfP8pGw8gHIZ05XspUbEFkaBQY8uSBiJ3nP2c8euaj9BBm4Kvnv3ZYK3p71hJbzVBI42cOkLd9kawctx86GXzPpuK6zNCOQEf4
# DATA OfxZtHNaCrLLoc7ZVNJMOidXaRDzh3hlJMrRWefKTN6y2zK9ySKFYeXwJnJJsNKoWje7nNJgTkft1lLq+qFJL0OYBrVMEMQgBUpw
# DATA 3anxuYOtVFGuoGPcaQziTOT6wgkdci9g/+LumoBqLGojmyvH7GH68ZhfmXr1kXtN48yr00EetKRH3si42gH8o5W/l1Bevm5SWPrh
# DATA JIWlPyyViZtf1VSsKxICNXVYVU/chJmqLsWDD7rgHLwleVh3m8PN3mEfYFgR/ZF/C+eFtIao/Ggrqas9aoJ9qAAep6UE4qYge4EV
# DATA TNMfIW636khzpLrBJVTvGnqP61oIVFTNyjLQJlRZAXccR90lDwGxHXBeF1eR8LEZ9ehSsijPYwcojJGvdNyTRBrHqIt2K8PbYNY8
# DATA bCfoLWcp6fmLSm7PIQwJOrJgJgosro2B2jd5E4QDCudTCvrZBNFCo1ifqViX9Bo96o0hFfa307BUntd4pgR+SDWS0zaHfGIhxpEj
# DATA INIRtDNAXQle6c1ynXSOhszpWGpAVfHByE4bzy0VKHeQyZwDq9PA5aytagK5WCLkBn6xsqz+x318+eWXr8LEJBQAQKqGbv8IQeOR
# DATA WDijCaBgItJpT93dgXDQdx2ALu9Dp1U32hVV2UKYo9vmQrJJDvAwqCXLCzrqS/YgZDAqwF/9/Z/WZHhk6Bm+T3m1O2qP1vxNjEFg
# DATA PC3ebb2NfjBw5fBfE4+DvlyoJStekBFl5qULMFZBYKl0xQsxUsaYMMeaaNiu4ddKKGvuK7FtPGqTZJZWKilhxQ5HWd5xcaeHG7UX
# DATA 7moEk9XYHNiNtBg906gXnYxkQnFN148ZyVBPmHrExF2c0itNxL0Yw4F6wt5w/RQbmyxbTTK/M1SsLihIM3k9sNhcwNX0RkrQh9nt
# DATA Rssc28DMSJz4ab/TwyQDi6QriE2j9aGvrGBKn6OvMkMEhaA4gCK1li3j5EwZL14UMdiawnj8nayZDqM1oqhE67uciHsZCUO0J+Hk
# DATA HvQJd+hy/9XlZQgWASSdjMNBENC70b9nJQudeYklPqH2pDWovOWrUHNfpx9w3B6PR51updXJ7jXGGaRw49WsHIK69DWHQi8kl9by
# DATA jl8z05tqdxwedg4g5glwfO8hk1Vi1gmyJX9D23w/qoqTU5mPA9yv1KtwNPRNkGR1JkFKBLn68kTtf/DFdCv/HkAod8cZFoYQYdhA
# DATA jJKtaHhMpi3Z+xZSthwgZLaKhR1Dl0vOyuJZkD7cT5G598ejwTiSi8z+4uBYEUAB19/aExodfmVlhTSHCD4fEiPpqenukkd6Jsha
# DATA l47vt/0uhDdaytFmqwBB0vqzUnLplVcuXsqPugV+g7XMCjmOrOQDNWOj4bgHq9HKiSSmGa0wED40FC9npqVMia9yynJ9h4o+jiOQ
# DATA 4f2scpid9g4KUk5NYq9fcK2KeIJpa+LgNCb1WOoSIRuH96q/yT2BFAXoFjZILTULujsg5DZtFLgfVtBVkd0Y2H+QjNXiTLiN9AiV
# DATA g6WoBUHv9tvN7Q183h4O/ecs/XROMCwHLDBN0KJWduFJYQU8caX4vU63axWvtJptiq0BtmU9x6uvAJBAVKgqovXhTmR/EOY/RZ6U
# DATA XtDwSsEV0odRh30JJDgeelxGusQvFzwwNj3Ugp3wx267giHq1utWp3nU66utfgDLYhVWTdHmWrl08fKan6ihRF3JlPjYVrfAAzfx
# DATA lFOJ36L2Y5FyAIVSsIBPjKMd8UrwtbvWH3dbDButRCwUlYFZoIxnjwEhA5lPO2/sWyBNo5+fEeU2ajIGUHPNTlzGWRmvNXt46VCH
# DATA TvcUN5Z19lwxedXMFpGkEC1QnmNSBagpvC1pQgec2G5bcZttesA7RdwEwBfFGqUAdKtGuzaxInEfAM6PTRvkEonNDPpANfGzLYey
# DATA 7FfBGhKryXrNQXbctzdFAZQGqv/jnr2d1c8SMSYsVMvhUXbo6shTZUTRb76XrCccKidkcdK8p+6LdGBCjB6YVrskuiFURadNVPSz
# DATA sRKXIGtIuzMAazHXd9A/biMCo4ytktxWcwcexsm9dnuQuRn1zMpTwgzFhvtjQMOsSMJ0jb6i5qBgM1d+B3HCPFBRTtYhfwO6h5MQ
# DATA psRdNeJ2g04AfghoH/Knt7lMpxwgKd0ZZhZFK4mbp1/cbBH8UNCzxM7LzBZfmGpbA3173OuhDBRJLURp7T4F9Rz9ieARmFonps37
# DATA ylGLcz40GxUd0wmRzu/jvGBQGsSU5KCsZLYKo7a3rlXj8DPAMMKHLEYbL4aXbGU1Ix29mM0UqvdMPedLPOrN8aNp+lJL3R65E+hb
# DATA gOV7gSmaIOlRp5e7U105AwBVMWEQ6yIVleOU00NWR9Zd9zXa01ON80azDZPPCtkcKzLVV8/L5Rif1b8gvvcnc0yf0eMEk2inkVbT
# DATA 1GLgdItpOvsskNFcLTzUUCE+CMd21bttXCcmk5krc69FWT/VjQouFOMO5EVSfDBp7mfA7brtoyZCVwhaoanMkDMeaCRaLUHUGxym
# DATA 6k+8pbHIklWSLcgjlGQP0HSN3LKLAIMV/7415dTXZigcKEkaGJPl0IPzOtdm8K+U2eRT2hdk1LdtUE+jiytJzAjn7y8MefClpPaI
# DATA 5k9BqATKqvAbjb+Vr8Hz8x7tiT5ykWloeNTt7xfSxbToUSzo8jgTZ6VLuGmxdElR2DWdbVdbOd30u8VpE8lWFQHcgxyWjwAUm2Ah
# DATA IKnlXzQMG9j+Hofz+jS2aaaoFLVWAwat0eGsEbIKjm6oeRpGVN/apgBL0Zs74N/nkoRQxOPnv3z+C0GlimLSAY0hUaBvoMuQvQnA
# DATA AXl38WCxZBam3s4PKJ12DwDZCjEeO4V7I0Czw6bRK2KW+b5ow2DjxA9J7C7gXxLO4adV9DxzdR7RyDfOniGZDu5SsHEYXdFCUgTl
# DATA Sqc/ztKi83hIWZFPgx1FKGaErS812wZ0eh/XEdO7OT1NGC4N93yNf3GXIXEgWl5dpR2CqXllCY8tUpq75EkcWrS4tDbBCwVUOX2j
# DATA eychpr4QvocYXwS5QhkxFHv9gpyk7GTzAsiids+n8CjsqjMZQGQQS4EYBEvq1dLDYfOUM0PIotDwTwgfEz7ZH/daXUC2mNvRx270
# DATA pdmUjcjHNGO5E/Zbb9RPZMyU2pel1aeSeYDyANuHEOQlUBPI2YAdMQ4zAnuJt/zk0X7iLqzqic5qgCi1nH3W72CcfmQDMqVYbFZt
# DATA CjtDpFuOpN+pUxU5jW3QOPs0lrmxktf/gfLsAlqcB/lpaGxB+/1llAsQFhlCYay0hesJqtuUGIYCh7oWd2y9MzjeJYP+A7jW9bMM
# DATA UiZjTrnmkKwOvfYDqzK6A1guRAki5WbHKNE8OIakC3KbFMtgs3easGoFfGgrlsKGaukQkpCFbQWSrZIN8Px25AYU2o2sEBwblguH
# DATA /Rn7nFsNOk4bCDVEThv4J3uCgmoCwDcZdbjqGxgwBAOVWGr6UfXH6f+yyq3G7eu3tm78OHmffolgrh9s3Xrz1o0bt95zSXIU461a
# DATA K2qadL8KdCTWl6Sysr9k0F5Q6TbURV5djgWxl/MZVYOL4tdydmd7uE5Wno+y631z0uQkH+ltqTj5/z74HcoZkvTMzleS2GnnBYNQ
# DATA IlJRU9sW4ZGOVZ3DJ98FrEIoVAXPv1vECT+lQ4NBkvZ8YGhCxaJLoXUEFr0UEfC6hFGOLOTBA59pEbUuxLJxyuQSHlcu5kBWabYo
# DATA VJM2iNlEluUZ23eSzFspciG3kZuAnuJ7DfesLuS3GvuS8afUlRCZAS2+oixM4PgFrjb60D3/SHJhIv24OWOf/Y8peQlNDk07q64X
# DATA 7obROXillLRWkDlocS9N8OuAIdndkHjBej1WK6C+6sPpT+T3CDl5PhDENvTLmt4YsTE9ocW6k4ZQPzdzT/N5AUwdiR3IANcVFMxN
# DATA KqEvEj8h9LMnVzzYOTyIYL3kEuglH+SEQxU2klitwwzgh7iDP8Rx/xKw26yTrZII1h2ekqrUF5h07APS5wimyKOcpIeKgWdJudsM
# DATA cySQ4+ZfVME/ECi9zpNYwSweOv33h04GQQx1QgASdoh/jORE+QnF3e7Z00rYYEq0aCcD528wGThXClOLFGook1U6GuUhzNDw7P82
# DATA CLLqcuZ602IaRFVlWCHFuIe1QSefEFn6nrmKOMN6hu0jdZuB60F80LRboQp1dawmB63oplMPE9IOS/aoZIARA2hKZF4PW2ucSSpL
# DATA DCSNb/x6JDLBgESUIoAqGkejLNlDKqOHI53hi8K+SxKhXaKg6hLPYonvavAHxEa7UQwucyOXnnjKctwddo4mNDpG5kvqKWrXsgEJ
# DATA XSxvsE1+VpL4Qq6exOQyj6cCd9xokTH7qhPJZ/x7SFxM+QFJAMcN/ubmjY0dmOFA2LXyGof51z0saDtttAzZAB2r2XCPFd0orBNg
# DATA WIPzTgEnvchJOfgsQwTd6WfO81+WgOv83CRofmqnY40z8jQ1lGloGMmToqEFAscx+BxQ7p5gw4E7uKlFDcDXFWBsE3xtXWHEGGhe
# DATA 6MX3DIPYTHuI2lrUS9An3pUJp+qCJOqVntAqmiocsS4vUlrtdfRx/gBxo2zZzRAFCjM59RbdRS7mtYPHqZzliZtGSoOVmjZ0EIE5
# DATA zymctO7LYbN7ly8ThRMK0/FvLhXBkTb3TDC+iqdlw4R0/uBsdngzx6kIOchRe1aPf0/HM9L8P0bgv6osyBy156KJ6XRh4Yx5ExM0
# DATA MC9x+AQSNBGhFWrMk/jMTucdbMS14OxcCuL31dFc4Ust7+riXvXiqnuyzNzDgRaI1z+6nXmBiSLGPQn3baWzKrUIIBjHOZZ7HnqP
# DATA LytReqzOuba6GXXuJreGaEFuLaHsastwfyENln9WfMz4wx+gdgqHluBHTyQz/LOnocworbwW1vj6EtmsGG6qvLjEYjTQKQjSnmwZ
# DATA zUb/7GkJtFFad0dfQT4gK5v7k6hWLuwsCEI8H/8xhzxKKGlM/XKJnyZ4piUdIa+n/RGnTQARg0v+WUdVOUjJoZj7e+vC8YRvMI9V
# DATA 3zDbeAIDxw59xlcIvImYWeILoZjoJYu4tvl42jslJkgo7fOfy12ITeuoNtRyipUOi2UY4RVx6QUJ00gvpMpBmCbeteiPPURf0CP8
# DATA u7I+PBpDU9v4RmuC1I6tNRpKBm80itaXcEVvNPmTQtoftIcSJnVw3Ae9SI0xfTDXU4qhZBkaGjgRLqXgRlgZkHHKLG7jN/bfOqcu
# DATA xgmkjOTTHArqHab7gr+PCPeO+FeKmMzZcZl2C5bFBDvWA4crAXpM8JBRN4Pn3D/0RymPB+pkpLhmQJzqjATsh3qTjUBxbj0S1L4y
# DATA YxrgFHSbPcvvARtk7aj3WJypbC+JITvj6JpoRqGhMnfAnqyc19z5+EsZB711JgOTUejlMigOeA9CvaE4MERJp1xmm1rxSl4BNtHl
# DATA FxC3oanNmIugTaOegJ3fhjldprYiiFFTOksJfXPf01Lnv2dSIvD0qX3BjMlTahqyUxJEZg6PshpoyqeOTdHWtI5R4luzGrklLQWT
# DATA Xv1pDZudwrGCtXRGT5FM1WdlSXPZRFNZLUUybmCKzOlNIh5Z/+vXAeBI5RMCPjBkl5duom4N0ZSZsxUGWdYVYOaLK1O/Y1Cm4FPK
# DATA mjGtWeKN7pLktuVXjyD005lChDnPufjOp7Tb5uulK6YGXV5Znrn18aQyq6zzxKN+hfGodY30dvbanmumATM8/y2niONG2budy+I/
# DATA UDozMADwq6IPd50DhA91I5X4qR3xJoEfIzcrCuxYvEo+JaquBkeMTn5dpcR6QiG606v3z6WqF5UsNx+7Rh8sEx2VghBmv2t7Dqyf
# DATA pQlo95r7XVSZQBbS+XBGEM3EQGooKlq/ccPFH3HMSpIXAC8oqLJzXg8MnAr6POsoAHupAYgMpoz6a9LOcP+jaMFOCLfTCY1IZ0aR
# DATA k14ePmsBwAgmNYDRTRtlixBiOM5/vtkEg3csV4JRGFrLr02cbiSCXkRn7lileaoogtKhUymCTez10+nEaQupZnrpQQNetsn9vWKQ
# DATA F6bW50uS5yJ2BoXIAxfhg72hDir6nh8US0msi3NOrVVEnP2gA9OHGZOOLb+piA/+OZnGVDnbuo5xMdtxX4q5wz7PIroXCytdTJZB
# DATA XlJ+IQk/s3BsDo9krok/+JOS3u6zUbZNTbLcml3wA6L1wowZ9S5HNmHCiwa/sDrNvYzPYN6ApnfCv4/ZCnUS65xunGfTRS5O/oYW
# DATA s3vebrH3HyWCQaQErm6+ZcYn3Jz2FmSgJVIZljxVvdnU5jMTz+B+yuseZkIwHcFbRzHCLfh+0DBcw3xk3Qgazv4MHIKnDa2UzBqB
# DATA 5+JIbp6d3mA8cpBB0OmiauxNIKSTe2HVcfXCl5MoL6OYH8PJprA69HK30OXzyGzaBd5JuYal5qKgubbs1OZ4985HrhalzrVNc9UN
# DATA 4b6lDjj4u1jU6gYuRsnagtyvGSZNVd0s3ubqlqy1oKTO9PxcLEVry6rTqEdKFWYdzRbidZSNMtdD+9OMsQb6q+k95NINLj2tpyEP
# DATA wR/85YxuGZWiL/KUAIIekWakSIw0zzuDnN7A77M+G/GnnIxC+QHy9FTe4EtKjju4tZWuxAGh4bahBn4l7nsEgrY2oFjN2uCY9agc
# DATA ZzmWzzgWtWJ3KonQzlXFCtN2phYyCdOcfhBObDi3oDCYQS+hgqHqi/RanR7ijMebdLpYPE8HRNM8Zx8kHdQ33Y2Za+W0NXPJNPOc
# DATA 44I+s2mUsKHJfC9TinBDtF2KA7DIZJ4+MMC9WYNZAlvnBJNgZacm1lr9XSEHmh4I64VlCwy6gfy10bD2GEdLFoM6NbK64zQ0WKK8
# DATA DVOsu1bAwjwoixBo+jl6sWFGrTAOSXdEcmfij8KgJJk/HGLTn5muUtifi5pyxXqvw3teecVnh6qM42jlpD0P2YGLRq9Z8YzcuhoB
# DATA eAaJkAEqPF2ELVMS5rmOW53Gwj5KprI3yrlgjccpmMcCIvnLIi/sZtz0kyXU/phGe337XWRyowthP3SyAPhJHr7OCeVWsQEgVtsQ
# DATA 3kmJImZUM8cpfOXFzkAxVjoCc5DZIBA+5hZLRGOn7RRlhFp3sCnE5U47rKKX2l90VmTwUZsG6Rzgk2r+MOumklYDFSOnEIoxj6Cs
# DATA nXPI+SCabEi+AtKqUsJDw/3DUrQFq276Y/tVMaYerSadgZrhISA4dAZaqtXqFM50b0eF500SIk0u+J7/gU5ZqnZAR61YAPywhAjy
# DATA IWx8XgyAL1yo/XGf83LDLZviAiy0FidhiKnBih/Iv8qhPb46U4pdyMm/IjaLqqfwScm0U7V46CRcMrZx2sgn1VguFS63HkjQViWz
# DATA peGFBdVuA0mp0cDhNxpApI0GT4ATuEMOGQsWHE4IuAK4OIiXUp0mdMge/7fnv1Cb9w/k/J7j3TPTFRybU/wFE7SBOEPB5BacDYLD
# DATA 7Jxmo/bJBuVFtAdReBeoAntfSt5pn/JfkL+D/7y1w38gEsff7tzauo5QO/i0aAelbaJqBrNIdHoH3XFLkM4wNURWTXoYWY/jT4bt
# DATA nxKwCGedh7i8cbebQAOVb3n6Ksmzfzche88/IVgOhknQkQMlF6njlxTyaPFlCiJw86c8/yUgSp1rNf7qf83/qV2234WTU22jyuD0
# DATA W2kDguIvra3hv+p//r/Lly5e1H/j85WV5ZW1v0qWv4sJGIODvWr+r/73/N/LL78MG0lxRzLlSugfhtpJHhpSunUAM3DY7rabGaAc
# DATA UYTpSmW18sPVysLC7jH48NoFfzZWInoyOlbnBKLJcYAIYoB2jiCtzXG7O8A4lGNgH4BTqN72x0fHC1hIXyiS3WvbZQJRPWw3AaQI
# DATA zagQI2v6yOm7k+Pm/bbqXRs8y8Fq2aqovrWHGH7bUkfqPhylALTV62tT9IF9SCBi68P2wZgC/wE4CyRKAjFcACDdWUdSwD/S3Vnj
# DATA OVaHkt3p9DviOE58zsFPs/+E/f/qpVdW/P2/unzxv/b/d/G/dJy1WcBOrywsqI2QjZKzZHvYyU6a17odvHDTr2SCAQ24rQvp3wzw
# DATA 4dIBlkmLV/jbnz4Y2cVAHHnQ3icTQ1G3sHPt1jYmArmFSacQyPXv24U9SuKR4c6pChy47yyaVQHzTQmnkgOYc38EPvH8PquyI2t+
# DATA ARD1VTV16OHhuEfIHMP2OIPTsTDsPyhyyhLJr9d/kPz1X8M/Fc7o4sRK2w2h13uqShs9DnzWfjhQE7Q+wk97IFO9/37ivHgds+1d
# DATA B5G9WAy+zw7UpSCrKL56hLAWNZ5TefL++45MPtc3F5IVGRUXZQkxcyNXcD6Lbqe4JpAdTwv4dVJ7PVoV/i6qmZ4sLDQhuj7RM66u
# DATA ifc7cBcpEHWVMNWGpC2TNQCt3UtLf7e3XP5hs3xYP7s8Keu/1yblNf3jonpx+YfN/brzRP5eWZ18f6kCidExMyTMP+SjsCYO0iT0
# DATA DyVp2kuk5YK8EykUpscyd68lF1eLAB+qKAPWjbEdN3t4cZdzig4Y9V1LbZpOEzKoXBEwPUU3REvTKckuL05wcKsCh7GEpq3SHHQw
# DATA +WVWAcirO73Oz8bq3pc8gHOwqrY3jneSTLjxpaXkdjsbq7YxKVDSxAO7jHcygdwqiWMGNIc0eoqHMEBMdDAiUPWw2QXchv4Bn6OH
# DATA ybBzdDzKKnrZdIcVmb2k95c8LcoK4+T7U8lOYAnykuTguNk7areuiLUSpQFFPyO6r9gB1+TWS0OlFCpdtZxQe83MoFrQnClEKGWY
# DATA PkxmbvWQaBPWrJTIrq2aTQv/qfT6DwoQNbCynCwmFy+9ov57+dIannOAGYRbo5rsVSoV2kAcsOOszS6IUP1uKzkaNtVw6H520B+q
# DATA kQ/6kDgBcvYByNpYiU1qHRBWWIOxVdTagkghtfUp2WATqKd5oDHZEHjWWWSQwTpIpyNaahwji0GxBZW/52Ie1jzSSuTMvigtiHbP
# DATA YM4nJVyJM549a/ImE2eZmVmrI6kCEmfhjJdMnXlDWLYqMl7APOlC0NL69qYVv9JpqsW8CWaHw26/P0QGSqTQWsdkNgAQjAklV3Ax
# DATA 9YeqOzkc/o3kDADtmqDGrgICdHuSKIJSBYOW5OOwoUkxmZQsZ0pgQiW1p5vdo77asMcnaiRv74BjBdLQFCb7Zn+4SWwpym4BEbTX
# DATA QqWjzXmDh7KhDrrNzkl2xcY2Vt2ipwARqlaBjPemCtPUme4+bAceQF0NQG2FA8CXUlUtLSbrSatzeEjQqahYR4hMxXLuKYo3bBUy
# DATA vWSKjcFeFBKuJItLycQx/XDfFOnSX2hhprMcaAFe8BHA75Fv1uxzwDoBcX99k6eS1aizXwz/n7pzbNYvnB/qqtqj0TvGnhdH8Cnq
# DATA PD3B4WzVo89oU9sk3IkzznekVuoAio8VSkeG+aZaY7U0ikkL1m9zeHSfcjnWABpc5ofmhWoHnDW1b5QYcuYSZWQm+yRZAlA35tou
# DATA kMz7RoWqepdUpG9USNx9o5INunCvq6QAb5u88QZkC3q9lrwKezzQDSspdjCCfIhAjwUtGyNyT3MwWELdOw0xWxLBmj8qD47SYoV6
# DATA s31ULJxFvQvVIHoEXbaDhFnV86QOwoqdA7kECbSqyWppRj27hPZ7s9NVsnFVsZ7GMmC0dlrdtvfqIr0K6psAV6KE8TRy1Xohr1vF
# DATA StYGGNHt5rCpSIqCpSnZfBGmN8UovQPgaW5LwEEhe5CidiUNREAMsGn7PlPgtbZJVXiMCwnlSyDX2fNGCTwdYDOdvydBB0QkEEWI
# DATA vSVOyulwQxQL/GwaI7bnyVjjd+5c3bl2e3N7d/PWVmP31jsbW407dzavu8UhizZZ7EsBmvqU6m5v3FFdxkqNJrQCEkWBJC61jzwY
# DATA eFLa01sOjLQ+xSmVDYjbTHHXSpumMg8v9dln8AjR2cCYriPc/8nCtEDL2ueY9dDEjAfx73H18W+e/Q6Nc3HkNx+tpIKBHzJ3Dzuj
# DATA a2jtTlbUsWSNlFHAeKzMiL+PnmS4nQp026EdDkd7n/IXnRkSKMWooST35MmVhe9A/9Mwu/8bVQVP1/+svHJpzdf/Xlx99b/0P9+V
# DATA /ncb5Siz9uLuiikkQM2q9i3eKAL1iXPLarfUDQzzjLE5CDjlpTX5BYog+bufLSDIMzj1dDv7Yj8CdwIpMmzLX2AH1H9rrH95Mmqf
# DATA DOB+RxWOh+pI2qe4K6kVfDfgsF7QVVNqWQ7hJt8qdGtF12PS4B625oEWFCRB83vr6o1b194pmtRpgCDYorxpLQj65Xw5lDzNMkAS
# DATA 1DLiDQLQMr33srBYeGNQqLLT2Ny5vfFWwQbrddB7JUUh5N6IJaMwVsVCurn17vqNzet8qkAMvItv48FcEqyRNARiMaNlny3jVKkD
# DATA vK2eFoqTKJzw8quvFmf1yPSkcRNOq6sbje3bm++u7244mNd4NPGEmlwjr/i5RrTn3ILj0U0rj/91Ut3gEyaRaGEnh4TlO4Bv0WcB
# DATA l6KrPwgXYsYiCFg+kWsl8BPkTgsZk+MNwXfK3V87u+R215SUHlNwGgO58wjkNwxidXntMubGu3sX86bYZSEUrz9sFQ6KoA+7CI/4
# DATA p5LSV1ZfpRg0+6viPNOxvb61cYOkqQVKxY4uInZWHQwT447AjaA5HvUjHhIymYTL4oPD4I3Sx3ay01zwbBbOFhfZS0FiFzG0Ad0e
# DATA nHjFSbBzTXU81y+Q5yI+W4rzrN+Qudpaf3d988b6VWcb87xlFHppt8rZ5HfaoxFnkNft8yud69mvTSOAI3uwoeB0c5L3nFlEARN3
# DATA I7zLsNPCWOK0B36DRQfeG9sghajf2+ZJm7xRAZcedjWkEPZnWvoXS4+R7q2Xf9Is/z3AVZs/G5VyXfEvRaiTlBR755r0rY3d927d
# DATA fidn8g15JimE9FaXliRVukl5BXB/TKLobSU/bM82PRm8QCDvb9+6jf65FAWuvS5tFyOrff0npEfAftj7mMIsMeqY+yivsC51nqoq
# DATA 5FQ1rEG2oXpTwZubvd6qMsQPwSBnzWagKJACzoF6Br9FNye/BSVQfv9s3KaUJ/DjcNg8QuFDF1ZHrm4V0XGpNXwJh7/iDcsvwnLc
# DATA gb1Uk7HoeF6mtml1v727u73DNd/e+D/ubN7euJ46p47W2Q4NWZekasXpt2/furoBbEyJWaS3kNyw6jKxPh4d94d8J60m6VV1oVZs
# DATA BmGh/Ovfe+vvbjTWtzfppFHXC/SEjpbSM8FQhO8BFKGmYFJMcS/20h+V1e3lQXPYarfgL/T3StV+qiyr/1tJr8RLbg/7ilvXEz2r
# DATA cFvytJZA6iigQXs09uY+rije0Nfh72sEW9SFmOWSTumWkQYVAt/pgobfVfC/UO4yaFXVjVxUQ6xaQ+V61tb6tcM2MI4Zc8TQsYp9
# DATA 8kAByJpclaspXn0VUYIuutmtUjfoB2nh0LAlDVf698SexPRDwR/NA+gA6RVA7QpCXm0ZMBLGvXtZba8OL4ANU7cLNBx8ixYZqX6/
# DATA 3zpVkwmfX6jhazZlXekcFuDp62uLmLoC/lM8cybtSqRfUrHq2YT6UhlArsGrY1DYVkA+L+BzdRme6GlGv7IaupNRQlsurt4eKDmY
# DATA KipWRn3Sa6E0p4Q5M13k5Pn++6Kpxd8v1WppHy3LaKmjQhW9pF5p/cL6LDr11hAX9J51q1AvJoIKnpwddNUeFOJDeoSxTxYKSNyF
# DATA Yu11Tcxi7K7RsiFnX2oOOktkDF/SxvDiFTXwAvdfnooPJ4yAVdPFyAA0WMUVaZYN4GGreaZy61tVfVZbHw6bp5VOhv9yXHtWfEMM
# DATA 6/xvhf9V36rOv+R+BPUUY921m1SfQbm95fobpBGfu8dL6QWMQWzfub15TaIIpDLWriuGUywUtcpKrYuvr7J0SeTMaKGeaZziRwBL
# DATA prVTUOpL8lkk4OlP6WlUM4WHQylRZRDqDHItUAIX0oWZBhCR2cZ+xDwxnu5LTZmvtqqtXAEug/5LeGVQBfbbBQ5hMPcAvsDwoaP4
# DATA CsUYl8TBikWi/BtUeMngNuwbBj6adlhur7+10di8Cf8N5SnKSs5X/8puGy72zeHpdYkJKRBUBeSVlBRoSBE45DJdwQ/7XcWgHax0
# DATA iU2iV0WOeRaVGIRTmQ6zYEYqUISyTiPnQc0Wn0hHGjl/sZSjRo2J7AVeCSdjzIsI7kGqA7SFRSrPv4vQ9d+XsvlPS/Sngly3SfoX
# DATA S6OCxGVSF9YR46d9gJlfIZStzJDS6E/du1/UlLkHVdYFbwyKw39RVPLQRgKXe2wZHBd7KEZYI1EXGrWww4IeiLmtFOfrPONWl8sE
# DATA yVcuD9TtA686bYbss1G4qBf50BF5c4DP1YIigaVmEnjLRedCnMq1z7jtXW6l09zRf/pe5HlbFqh+/dq1jZ2dxptqx4J4S+nc8J5O
# DATA bAf0hAb/BLMu5DEfblGxrNt01qrvFT9ut0DHfh8Ty/OckPbxSpIdN4fk/ZFQ6gnFgU6tdJnA/SyPdUq+AzeIBZNULw5MxMmqXCAi
# DATA 9opXwnds86dVa2RpZN+rAjjgyYJkkYC6TKeA5WAGoawgoVPUDRuXFb/lcRMYkgA7RCvqj44BaDunHjeXDt/lSwl+ZNJ12BNTgZoA
# DATA 51wu+S/p/IsyVw7aBPaCEboIm+MsxaVSk3E2mSzonO8woKqX73AvtS7CeGE4W1wUViwB9/ZdmVPcSZIQ/SloGhYXafkmkcuyNXXi
# DATA G+xWTFgUZyk6TKmuC0GnMHb1G/6ZlJKAbEpMM+ao9O+N6pnda37foGRUs7egOi9FD3ETYnfvbO3c2Qb1gL5rhpogyMBiQ07JW2L9
# DATA +iMMjIspe0oG4lc+tckijKyiNCtwNJD0TCMFrQ5qCmX7I0qmOcABVtLR8kCHbD2TPpSsFuXlHsR7ScvmsKLnTgdeqnn8Z87pvnZr
# DATA 680bm9d2I9Nszy6GtJ2ps20Eio6uohVKr0vNV+Uba96bo1ETuBfgLYSUgfjJKdfuJTa15kEq4SlwRyYvw35OpkWsWR0DB9oC1IwX
# DATA PfVtVthbNG3CJBeLwW7WQ8C4MC7tOIwglgvxh7qTPwkZfgHflMQHkEMEqwsu99LESalwmDIt3qLWAjLfob2qsn9pjS0H+N1eSpEO
# DATA kCTJsygQMjh5H6LSjD8gnlDPkRWpT9BmST7AvV0PquNUi9+Z/z+Hf37jYUDT7b+rq2uvrnn239W1//L//87svzunvQN19+6BsRCC
# DATA U8jTxvU8pkzksIeadr4KcsEzoNooX6HAh1lCHo4s6y4/4XyHYow9POiNuvIDwPnUF/JThwV/ozZkuPC/iLX4nY0fg4Jy587Vxvad
# DATA q4rRN67furm+uZUurO/sbL61dXNjaxcjH1AQgaQTw/TvCm9Uyd1jL7k7ql8ovhF8ji8Wa5XF70M27nblJlj0DrrNLEuu43ako8ac
# DATA OhpuXM0LMcRef3gCzkjMsXJtfXz42tdwYo1s5aOvk9eTV1ZWya+SnbIgt+fd7O7dH7zxvbsPl5fLdx+uHN59+OphPWUWFljx7K6n
# DATA NNAGq9b5ePTMCMyjLXsEPQmNEVaAdK5Sfk5bAqOCkLkAriilZG3tYtQ8cf4Bwpc0Ql1JhfRQhbTT6jVTfZ4UK11IAsmmaed27kTG
# DATA 858FqM4JDzbEYQGtAH2Ex/a8vQeVANAEtgVW31fQmptWdNZsHJ96BP+qgbUoRxG4REK+MUyvav5Cg5+XYwhU1N1uwUsiq3bM8kPx
# DATA hr3wPvyl9k0KmEbDUZGvEkPdA8sRM6gdgTbCFvbY7qda4j/R6ndpZSJvim/M1d4LUD1nChRb1V61vFIXMqa0UTKRaLlC6pd3si5d
# DATA cVWBZVlbpmWppHK5gt90BTQZiJzxL/HA18s/UYOtNP6hXL+gHi35z4qLNO2QHOr8I2UBDqmEjCKWw4241AwoaMSR2+xkiti4zc0i
# DATA yRIltbiGHgFGAE/m6bO6Ha2/CVf23bfTyPb7JtyAeI8CAstWf/QmQLV4WxW8a3gmqjEHVu3koMfyrfoXFc7vYLS8usaJzu23PcBS
# DATA gtVYCdOjmlLn9x1aXY1ezOZbX8zj1hw1fZ8hawgXkpWivdmgeNEd5ovRFq8n1Kc2w994EhFsji7oD8kzxd0O4qtS0QHPwFjvpTO8
# DATA 1d67LUR57fbG+u4sii3Z6d1j9NW8kENfEbe0XGLTpPT1VjFQY6MsCTE0B/e4zRI/g7E1Nn6khmv93roaqESvwred3tHmLW+L5vTv
# DATA zvb19d2NxtU7Oz92NJ3yyWmn3W0x3+PVttdWvJIQswNckrICEuNUxyRNmlbCeZOIg2C5SVeCgOWmUE6mqfxp37q127i5vrX+llYd
# DATA aX3hlFTCNrs2yaoDnm1eOYzbtOCUiWOznYdiQP7CTMQxXEdaDQSIssq42FkLNnu0FUxQMYMFidSxkrxWQ9aBL4vwa+VSnnji1cUC
# DATA OhzeEcGFDmh0VFopraxe1o5KrucVNhtr0GqMx5vXdX6Nnb/8gvQi6Z/PzLJKFrEqCQLhC0ssQFy7yYJBhsO6JiaPNHaR8r1hZ23x
# DATA F9mmXT2V8Q8BLY5MYSwa593aqHgoBCYV25Jyp9eJIfBMn8Nrt25u39rx1LYRzhLe7qKZtItRdd85mzfiECznHkwW6OvwGHOnyLyk
# DATA 3wu+KUETZzTvQdTygiNCEvdtlnjiULmYQdFLnhemJI8lEMd9sFePNeV4zXI9UZAwv6U9/cOtFyaFUEDQ/S7IIG3XFaHnAn67R8ja
# DATA dU/di++cfOb4JLTy0JpKE3XZEfLAEYQo87WShC6uvhg/EAHIYDcy9+TJZCoSS6HqA972abNptQbu3E7mIY/5wjJyTZx/1E0bJQ0G
# DATA RqJxFz1nPKVu0TnAuJL8VgRjjgvuqfsceJXwLbGmuNlKcW+l7jifC4jcXhUuf+Cp+LIq93L6skVHPxv3UTSggst23pOWPMaBFLBk
# DATA SURW0q53uvpTKK8E2qruArtKQ7TiMqtXUputwLvXErxWFrAmuUbCDzsdcfq9tDg3Y3Evh/bMUTdXqqrdekRhIcVAGYWTqs5B1KV9
# DATA T5RPGNGI72orRZx8a65tJy0mK0llUZhFhsbTBXtgyJH2THh01d31DWlUDKElpuFck4SVSVouR+JRFezgsH90YZHMm07rfJSZ+ipk
# DATA jwwgb6czbLpTQkZny6k+ZoCdws8tvxLXNBu2dJiA9hUV0NBmNeomIfNAZfbUF3XjqWSnmHHOd/nKV6IunPNYZ1KUxkibiHoNlpyP
# DATA 2qgPZB13hdMdFBfidMEJbB3ysFqj6gQcQSdVEAUjIE7sp6CrBY1pwWsTyaNCVRA/EI4qeI7EF/bTk06Wob+Ps5nOUhysEuF40Oqi
# DATA QqGL6hH37Lj9UBqQPIlUvtOayD40dgcOWyFMjxqGADCSFtyE+K6BFydzWzB31PDS7NxVcnY3hxXoK5lJLELIZrVzMAqbf9Igwr1v
# DATA TSC1EOhcbGEOK7HM1Vl7xA/xmiRLgE5SA4Q8uS1rMIlpW+jbvbB0HaqjDu2ZdazPLzG+vb711kaMsZsdJY1TnynHlPcspD5H3D3p
# DATA twBXrmXk/xdmp9NYqRb0HXF2Ic8xZgpzfEGp1uqsfB0lpJmS7rmYtC8KT+PFMX4sd8cckTq/6/knZf5YKoP+oKCa90OFAqk56u0X
# DATA 1ocHhcghueV1XjXfAYkqCb5jnwK8MLbGJ4NMu7y1exk4EzWzg06HFN8lzHrdG9VWJb/wHG6L3AAyc5j//TQNHBRiBynugZfcmwRJ
# DATA L1rQs0Rltv9BYznLmEt93EG7svE+BuVgbcHa0673igOZqSmpacMff70wjZI0H3mhAXG/4R8dhgMuubw06p+gU7FVAzcuqEKfyC/R
# DATA jTlsVHibvjs73/k3fik9z8GiU2SJQlESnbN+UN0hYzkzyjAwMJOjc/xaoQinudMRqsfV3NGzr6fS5XopvQGoiGvL/VcBdoRSOmSk
# DATA EcpxrDGJqk6avc4hSCGcwsp4GO453YtmpZKMQ/jQZP3mnFeYkNDWg0TPLc+P12S68iQxq6KiLTLN1cgkENixtyV9zLV74xMEOy0I
# DATA 0Zipq3sptkboAm0pPkLtummgYA7dYryhiMhqkU/MBIgrC3RkjTu+Qc8ji1iN5sxnThtxyirEaYKRvbn2QKOwML12M5mzv+SlkrRq
# DATA rt5SjBjNrL2Bf0IcYLCGQh1DcEPPlNzMdZ53qQiVyeJc1TxZwZv56Qc92nLHPVL1L5z/YI/N7dyLY4yrFlPV14BF577wvwYkuOP/
# DATA d9I5Yny/b9QFcLr/38WVlYuXfPyXldXl//L/+y7+972XlsbZcGm/01uCoInB6ei437sIUWK3BpB3PuHMqBA62uwZuMwAl9SBjgQs
# DATA Ts8rkN3pmsMj9Ldb0F6Bg1PyxgNNBuxc8cST3xTI+/dwG/zaboABfAykLBAkGfDym+0XaHsRLrxwZqooFE2rTVOqTjQT40+crtvc
# DATA V2wvREK4xgDIRpV2A0s6MV+21ZYq0lbjCgUsya1Q8rRUwCtbLWRDfUpACwJYBm/nrsb61NyFZ3wqoRLm08CWbOugOb7fGmINgv4d
# DATA MJLj5hDxSFY1Hgk+sSFJ1AM4E00+MrnSypDdG26+PUCjN9gpcJzsNzwc37Y7G4+C2y7mNy4GpzkXmW6kZHViOA22W5Tcqdc2YTYA
# DATA qV80mWLCpudTZkXsPgeWMq1mqdW4SzWdxYsHW+N/S7GYO22cr7E6DoOp7qidWYNdaN9gioKTI+E0zW5HiUmZ2Wh+0FnGEZUYePnC
# DATA YCn0WMfSSjjF19rOooXFDEOoqxb/Uco2JNEO5q6zWJDRMGIIDV6MnRAL5ZW4vrUDICtWkRAPZxoWS2n2yN5mp1hOK2igZM/BH+ir
# DATA ur79i2qZcq6R07rjFO3car4JF+Rc0JMzD/Rk8t2CnszhSEjPCqbrJddZmYmqZFylwSS4tnbRG3DN+F3jVF1eLuZbT3TKohxuQetH
# DATA Ce1GfUpBXMD/WiQFCrP7agaAUbu7tcRh3NNxc0rR99gK9ZzDHWouIblbJBbwiUSpWacETeRYqo1xiCMuasmZ057qHEan0b7mYDcJ
# DATA s+XgA9Xim7dvbe02NrauyzM28d7HfkL+9onfox43GfRJ28hApGtYUYJof3hxNrjgBR1mbZ7vF+CogDavJDMMyi84/aRmvpdcR5Yh
# DATA mGgZ+341D4b9LEswQ4EO9tYhbKM+Ap4foG8lJmnkyn4KMPzwSj7hWFvCIFDPKQhmvw2CL/lytggfvXmy3zka98cZx+VyFG3Gnszw
# DATA lWgo7cmAAHl8geWtZzWmRwp4j1+OGZK/YMXiF6x6zr1mef/D/iE17ZETg3+wcpyxHKpkMzGdiqxbzMqiA4/Nhhda1rM7ZWMdxlEJ
# DATA XNdrPQrmof5ImPvEY0ID9bfZZWq5NPKVbgRYF4Bm3c/H7oqybr0xnTGyZ6nAqWcBp8wsVlkjmzTh/TcgDYDjd692y7g7MkrArE3A
# DATA iqqbxkht0OvIjMat2Jn0ABd0DsFmE1MNOlLn3yCYtq6q/6CHBj+ssjLkQlVyqVmuU8LH44NhpdNf6vZH4Ee9ZMKFAzgYx8nFmgQi
# DATA ZWhrxsoO20oA6fA9yu3UEnWqvKI9f6ruWFCTpj/XIkLYSSfkOXw9mU19UPn85ye6jZkfvp7ZLPFMuh+1T8BBLXaH9SLICwH4gOAR
# DATA yL1RP9CB8xRIDm2ExmF5AwsJLfD0AgH7boagOm218FD0dhkQv6hVoTbH44G9MagURjPXuor/tJrYcFVGNKX7Re0FTlAhEGysxG5I
# DATA eInSSM3C3VA//T2pHhX2Fq2P6mQIq1Hs+EFzAFnEGv3xaDCWhyPCnaqtXF7WTJPHScMCRaiZICvHKMf4k/jr3CmgacvWBjQsOZiS
# DATA dIC3SMbIhD/HKP8yEEo26tNPhEMRMBSEeJmA3YWhUyxvU0o8g75f2GtK04jxThYQT7uZEXB/wU14lEJ+t/HBcWLdGCAz5PMPnj0G
# DATA nKTk2VfPP3r+IaaThOyTj59/DMkhk2ePJbVk6kHNgwv9vZ5iFclht4kjZgSnDzGlL0sd/LFAPyEw06fY7H88ewrwTdSKl5EybAsy
# DATA hYD7TR9gT3qddgsbtOChkmefqe//gnku/xlAzMM6rjV7DDEKIEYi43BHW832CZrHUn6AcFY2/tSTWJ3MI5rs6mSpevD7zzEH8geY
# DATA gfMjQLtSMxNP/KleRCa66K2spka0ywIxUoZCon8yZBAFKLKkV/o63OkJEckjIDSG47LBt2QCnuZ19VeJTTrPHqV+slC5UITpZguH
# DATA 6bN/oVTQajo+ffZIWiuc6S03KTK5fIYIX9CxX2DK6EcAjF+iXn2anAXbd1KFhzD+SSWx81FLavrH6p/H+DEgg0Hm0+cfuc64ZnMp
# DATA ZmG4FDqJAMMpEEYPqlhs16wgFiSElPGctWJBIWDoDTV4WJ8p1+wdHLs3Rp5tWN0CTO8jTB8LKbb/OBsdLYfQHRXanu8vM3C6JHHP
# DATA LnckPRgGreFcuAEkxbo9C7qo6NAktBFeFIqOqS5Qr7nD/+9O/ts/aQ70tSaCqUNDWpUSGQ6jWdG+L7MKJ6r39E5Fj5VYlRiiIQW6
# DATA 0cOq4w7SdeN0INCTTAdBXA7RlXUvLR/yl/CuWK8LVghbLyhOqUHWQIbGQmUhPyIDb4O8EHU6bM51GjufVWPddntQI2Ru+NOgWNmb
# DATA xBgeYlkWIJLO/FrIBao2veeNRLIWhynZld8UC56JVwpDtGCHBZsVpScuq1fMlNSPqo7E59P41OApTJ1SC5lLcSEvyMaVlohgGAIt
# DATA XSSSFOGjXO71y6gaGGC6Av0MIMKQD2E+V3p8CK6JeGaxhwisMIhdvrHCE+MWPN88xzXbC73Bu07unv2t2ql/4M1Jh6S7WyMJTeYR
# DATA WBZsTHzkoobMixXKdQCnqYuGPwti3vGKBYtdpaUoHv5gr7airzKPAKjxn3Wn6B6nnK/Llcp5i65+6f640wXhx7j7ma/PCQfmavB8
# DATA QLDZEG2mYdJSS5texV1HaQ81d/oVfa0TFXYZso2p+iO3wMmC476FC2nxqGLouYXwlqCbFrMpZh4Uy2llPDrAJT+EJ4X0Bz/+wckP
# DATA Wrs/ePsHN3+w8xPybYt6fe1VL7Oi6RyuWYj4kIhHGDhkURQq7jWaR3apoNkjAcMKYo3OSSlxoPWrsgkhKtkO5qwmmtQmC6FHCHau
# DATA pHtQXJjmSEb9JtIXZ7L5vhRzhfst/WJ+J1obZ6b0U2u23Das5Hn25nvQzBpDgudUFRoVmOB6WrkS9MW8gaEKHpOlW1y53KQLWrn8
# DATA s3EH0+fq+RZm6Qc12fUaxmc6EGHsDmKmuTnaNVnM2daouON1EEZzYUs5IIOtE737BCJmfMqtJBKm/9qNvVWyUh5YuLAi5Aa7lM39
# DATA Nr4law0aVc952e6MDTkbYmXa3fHQMnP8InMIxnWjMtXmWU8i+LAxE4gl6kuN1YUwvVzFQR+ODIqUlRp8mCfO0oBU83Up5iQnQwhN
# DATA bXWm36g1Xm/j6koiICEBLc8QlQNdUY4gHNGSGTnXZOGszxSMZAPL1ATzACPojBrcaWGRFt3QFIWicTG2sjY+nzdvaDlQpe5H5cCS
# DATA K/ViN4rBLUpX9L1kZ9QfDBCG7EigXjN6VEnWE+EOmKmqk6k+c/pWNN2oy26CqLDir6Rm8CHaWK9frQRrS53WKi0ULFttYZXqhwgp
# DATA EZzfRUUZ5RZF6NpcCxWZe/Q5urTADSnksraa0/o8dOxsoDIEomoKl5aL8YjoCNvXQ3tBxu808Y3yev9MoRk7C+ObjtvNLoZHTz8G
# DATA 3sZi9hMoMs7i/sLzHSlkqeMOgD6U+FZKT059hX1e/Xn2EfSIJpsKALLl8+WAIxsJFutArjrba5ZvJ/+qVZdwz2DlJaLXgxbhS9Ce
# DATA kXrpK77EfIa6s7kSNs7QSaRxY+C+2rr3Ysska19Te7Mns44Rb1PXT1aedNgtdTEibbTiQ628RfMm6fcz72sG/P/5L0CZl9iqx2ef
# DATA P/84efZHuNThIwb7j84AahgKq/PAmUd0Qx+hWvbPz74CdSBoZr8AnexXqI/+lAfw63OtTM7Vfw72HT+DG93mKaTIIO3HN6+0YM6x
# DATA uCjCuzmi3+TIkNiQJq7EFIoOtloJ/3YcX3Ic8aUKxnrVxy4dsvMfqQb21o2K8eT5/8QTi9zpSRMHd7eCxrQaZpiaR7yBK+vDozGw
# DATA s218UxArohp7rdFQx0ajUbS+BBteo8mfFFKtRiccfdA31IBMsoM+I+1nSlwRkxQqBEWOILViu9siNSLFRZH4xHZP+EVmNTJisWqJ
# DATA wGTQ3iWGbGSxqY4gKsMdAH5K0hU07aLYhAYwzHAyHnZtlVp0eGW8mWMvp0xCuYxxKRBedzpo13RGLrTY1eQb/Ae+ysy1DX5VLOuf
# DATA 4qR67vJkZvoGp6Vk+x84HAALkVeVOs096Q5fWuZl1zEBKVruKfE+8ppacjgtvc+H8FNaLkeWwuc4ZzoCkbXxy+Dgar1+DX1fuXrf
# DATA PSM4OH0LGB2UX6IFSLH9c/HZqDaYBmS4jS6YqwoGyYh6v2eGVZ+2tJzd0OZpzmkjenW7MFVNFzr8m29y+LejYccn+i6Bv7SuXWvR
# DATA DfU01C4B+7latAYaFhoNpIBGA5hKo5FGfDuJ3eS6IerUF++0T2cnvgA9fduDVx2CH0/67N/xKH9Cp/f/3963Prd1XffmM/+KY7m+
# DATA B5AA8CFKTqCgDkXCMhuJZEnKjgsiGBA4JBGDAIoDSmIk3omd5radZNJp5366M22n9965nxUnTmQ7dv4F6j/qXo/9PPscHJCUm+SK
# DATA bSzgYJ/9XHvttdfjt3JaXCwzHxhu7wQemyTrdEtkeeQkQJi3Gk70r1/+EzQClZHFEg75z6F2aL8SCEp8zr2BzEPY9Kf47sdoKkMZ
# DATA TsgEKNKVAvHax5TJCJTRf28k5caevQDaRWMRtgkQr3DbrEH8A1nlDVI8pZxDhcU/jwipP+8/S+WP9+grh3/Pjv9aXFheXk7gvy/d
# DATA XHwd//VfG/+1rWHeMVFHNCYEDtLuJ+K/4jvi7BS8fL83gVRc0smBhdE4XwxYEjVeZk9ssX+CHyn+4hFhmH3xjz4+bCYzMvbRH9ep
# DATA sfi16k0ldisZznumUFeyvOBZnO8BYEVvckoG3KoF+WzHuBfCvYWw8qMhONBD9DTcsz6SPu3k0W5qPUPDoUjaXYtFjWxkxck3qkvL
# DATA TYUr3RmOAUFVwwBhELr2aKW0bgYcgsJXTVib4lBKx/RSJgCpmRGGcQ226/fWd3a3PwxtfCcT2YnqPewP9wvhdYntankmS48QT8Oz
# DATA NG54DFhypB08LtuDZJOodPIscJ60ufeg/dXN7bVkQmaoKROKVq1Z0hGT3OU9S2dA486pccAj7UojnezVc8+EeiVtIyIkiblr0swW
# DATA 6epkQ9NBdxMj9WYUJ1fgx+1HUdlrDyW4DigIQPu8xbwdfCjYE+QJaqKdG7Z/e0B4XXDTOsszRn2fuNRAs28qnBti0PtbhJAysF6R
# DATA giEQACozLiJY1MxbZBMumVEsFEt6xQ9jadL07uYmwFd+iES9Y7tFUR0ybpdvyzYGGR6h7W4Zfcy1i/XwICAfUjJLHKPpgrm3DEMR
# DATA 99HoSbsjKVYmrSM27ACCZ20ERfQtx7kM2ZH53MfbOMzwzGg7fZfYYKFGaQ916OanQlindce660newDYF2EtG9daOSjRruhSUjA0X
# DATA Fs8S/Atf9kZnGDaJXjc2jCuWzSPFwCLjH4p2gMJAUHJMqTduy3BmTx77dvkAgoafLi6Vbi+fhX7HRKgpLwtf3dzYXVnfqG8DZmd9
# DATA Y3fTPkgUIc9i47kOHSAXfjE9pEbU+gcxH8PHhO2mF2A+heNhMGhvOJ9Z0Ke+V7EiU5qYJaTkLBkVi/IGMiuLaxnxFilGGH06zhAs
# DATA 4wmLAS99mlBDwyPjCAxC1eoyYylyxfh44YGMKiuQ204QQzIuqaGqa5oxnI5dw6OvkWqaYg6gZ3PeuUfJ84hcy1TAeOhDk/OOkZ0Y
# DATA Uzye53xwNuhhwk4K8A+L+fGZF1hQb1qPRcJvmDJTpjixyR4c62QOlWw0Hk6NJw4blYXGO0qJRtoge8h1bIeHmhKt6HWypplKGUci
# DATA lWiqfTVxtClIB8yzA0AmcdbQU8VrlHEd4DKn7WFckblQw4Gpo05CEGJeFpa825NCMQsrMW/KlIIvZ4oZa0ozQ7738DhRfnFhYaFY
# DATA zIZPzJ6gzQ/EEeLPlezz/s2Rm7iYE+SdmF3DlgOblqshh+kKgQAdws5cKYOqmJuaLDmX9tgnw8zN3a/fW1kl2ZLSnO+84vMv7xEo
# DATA MRTYHIOBuiimWkAKPJSU7HI6s2uO0yo5ExIg+GQ0wsvylE6k9ZS2QmoPbcDaqT2dNdy0qLAoDiNDWdMaR0Lsg7uC9NyoSndE6dOR
# DATA 7YFXTEr3Gi9Aua9NgShID/x3XNuUCRqjvcDajWdmVlva88SAQ8jIVJcjwlkpsFqmrZEwo6VEweHNGl7GDMMwHInS0qLlQOBxUZly
# DATA CtLaJ1IHOalUxXaoUzGZKMdTQB1peVRR7nF12QvKK76cXORictWXEjcU/kC7E1nCvLFRyKXOdDla7xoYVmnAT54pElXlwBiwyVl/
# DATA e8PphR+eR8sCSf+had1Te4Ba7nVNPC79azFfpLqXx+dzjbtARLrJQR3FJB4W9v5MkfFhjp1Nmacr024cidvGDDeN/LcMy8+7kcxH
# DATA M+PtI3nzgDk1vjr8jPIK0G3CD7h9kauEHpTWMo4LUy8Xzr0zx9XikteKC10p8l4ncl4lru4akXk5uII7xuz3ixS3RE0eczlvIvlv
# DATA IR6UEBNJQl85MP+Fq5vWfmbiR8FK0wR3cM2LuvGqEsdQlTlFrjy7WgiLkppe2WWNakHyWeSKZCrWNhlSS4Kr7r4prWnNVC65z8EZ
# DATA YflEumth/tEs8QKp6cH6ve2V3fXNjdbO5sPt1XpoBdpK5ykOPxoRxI1m6mJtdXl65K6Xye1HkGaDYKEsoyWeblC51qNzSdssyA8T
# DATA lP5GLQfXTpkA3E4q/duD9Z0HK7ur7yUtiKBb5/YFX0bipgNGeoTR6hAibP7Vdx+UjKWHNmoJSBZoQd4T0ROQrS+ybdSBtrRpxsI6
# DATA SmZ0o5fM1OgpgtASSkG4SnmEVrrVrtn0NGXVSXkZ6xwG7liqCRnHsUBl1zl1N0DiNjIi17fra2E6bmmeS5OLhJNn1nbq2++vq134
# DATA JgoUcSDOfzR7lQkZSlq+6DSPIQ5OTEGwPx4+jlF5PTqZxJW5hGTT8ARWXfdtnGYinaRPwzo9M/UFTPiuQJByVkktjHggc+YxQHNL
# DATA yORABLQlkkiraSAexkVTjyQnsq3OuNfg/YQ9ZcFKfifIFnMDcK6AuaSkkoYrYkxyzckZ63r+A2gefWmaxwP3FdM6Z1HkyoO76/ce
# DATA bj7coSXZXdm+V98NZ8sRaIxdJwpckIHwCd7l5NpCwYGqCDGCsOqJIFSeANqKxI/w7nemfGROQBAWogC3Nzg53lfqDLRYIx8JGBiN
# DATA Mdig9TsKVkQigo+iMeAoxIgphIhjuCkxyA40RspsDR5HmG1bieTYA247t1biT0QZYVkCr0IbYWyrhF3RaIyZfK54NZghE5StImRV
# DATA Cag96YyMUrBq+5Avc3CoYXu3xPKJ+zfuLVhc6BEXgk7xx5ihgy3DnGispAuA95fudAY4JbRoQoBydpGmBPzsHRxEqJ5Z39K1H0M8
# DATA KIB1Bm3sZyXYwBNCiHNAx+2B4a4IOUIjgCv0MglHhnT2t9a+JLb3VFQ8QwOR3sA09YEUSK3bBXMRPiMdocP4ET08a6pkUnTQxcwe
# DATA Gq+m8jCu4KnyeWSdgHJ4dDafrjURiYVJ75JxcWnX/KmAVEoHMF3rcXY1AvSbwa7gk2pBYIORk4/kq3L54Lx6FCHrHcdHvREg1g4I
# DATA 7khetLqMP5mwLPlOC3NWvWeGLuA7OXJifSWNB54M7xDm0YZw49ZkiNRikEJOM4HeFBdAGp1LwfFUth829lRc649K/u5PSZ+W0L5G
# DATA flrGk+HYsVWqvrwxo33JrcqRszUieDrIaIpnYbGYxeu8gigzTEndRcgufAHvOqI8D+T+NGB8fmjD7CQzm5lZJYiC6bEZvEqPCvQP
# DATA ZUelXpm5ku2QqTz+xADZg3wa8kaRt6/pm3gJcU+PQop50hHOcN01zygpiSTXMgsFwL3HuegvDDRJrWRs25xWkEuZ2rjRC4AQEMgM
# DATA W8DpKmU6dbqWIelhnjxck5eexCU9kaZUSrPwPLGFklHw5FdruL4al66UPtArvoa1GCadI0pokvX48k478qWXqOFsljBuaKQIi1ht
# DATA uF6ux4s9Y0i4iZdQtWY4eaYDP2BqXV2QH4OHiMx8bI+ezxxvj6afPFP9SXJ5kehRllSHwpNB+1G712/vEwZMmKaPvpLrZLqamvqF
# DATA yROpgyHHjotH+8Nh3/RPV1eSjPoouLpK42xUxQWv6fivY626m/qnrGq1/08q2Z95QFLVLbrdPWXEGgWyvCQhVwBLgnPu4hFxPBT8
# DATA bjjodTArN5cnyK4jALRMFPquqsIHouXfLjNvFdvP374dOp792xEaePXvyQ1T1NLGWJcGQrKBNRLvZ+xMqM0BU/FC46cMyaon2Q97
# DATA 32d0wwYWyWLHGgtUInVkqldX1j5UPkJ8qloKbBXtrnXWOgBeC3cIw2DCa0fGI8nN+kNxnc6vr97cqpM1xFZb59OzazAKq8eytyk9
# DATA onjqLMkEQCls4cSRSJp2g4gRQO1J4ApsFCsQhz2KN4sLCwoQozPsD8eeak07sUFyWX1VvWAsDQW+4emjXDCp8ykmRa3kbL5R4xU3
# DATA BS3JlSRVqaAL85Q2VH0TcWMhTR9o8OTqKnBTNNpOIBQF0BV7E1GO1YGAlAUmxGgEGh/MXCqVfdPkgz9aDFgb+lVjmPpQXU2jiufK
# DATA JQtPtbOwmQO0BTvrG/ckfCtq7pW+zyRFVndtYhwjWK667T4YiVj8BNMgIkriOnFYS1wJpFZ3ctSeGHoFWHquEWNGgQpIJXEIqjDU
# DATA M0weD8uSIHRGR2lractkOEgSFca17HZPEao5VVcAd6VVWYxEFdGrFiGw1QAEU/wWSnmVVsAaEoWyqUu5HVxoiAB03EQqw32M/Pxp
# DATA wrLNLdquMujeJHvpCSe0ftOqANo2jthkXqnFfqKNVnMvoeJqGDzdG9Buxuy8PCeJ+2T15sLiwt7gzMw6fjwUl1JKrkSDbfCwmtSV
# DATA R4L8j625ww0JintOUGT6ypYwWx+78lIFACzDJyLoWMPUBERcnjFy8A3CLOQJs2tFcud656NJZx7LzWsCIRUdkAMNsWimiFFUoz+D
# DATA 6woNy15CDX+MwcSCd9VkGmBoXK6LZreqRrnkV0JkmhJ4p0vhnAtoYB6wY7R1SjnJGGR75LdMZBZBDXGL0p2fFZ0sWfymdZnB3Ejt
# DATA Y+kNZTIuT/buFA723spOa62+Vd9Yq2/sSn4mtTk5IKPTMtRTbnojarDsRzv2Z6mfAatY3VVngCF24YabOkoVl0svVdXQ/tb5GIUc
# DATA YSftPoN30XEO0JWCew/FnVNc4O6wx5I8JQMxQ6a/+pt2Bo+AJYjgGDKVkXIlhmuAYOTtQWBMIp7DWmms+AT0uok3wAPlNNUw8hCZ
# DATA 6wCzDtU0U6uRAg3UEg6G4ewIyxp1KPu1/OWnwzGnvmkDMtuIcHTupobk5lMDXiC2lxz+2/0WdcCNyDW6VSQLjvquPBSdPEqqRhVo
# DATA nxLiq8N7s6rT99WnQBVVMzaX95kOyoUSZ0Xf/jljfzAANe1asNb/9Qi8qSSSG5FXs2PMJehAnRQMcCU/5pgD25uyOzJIWcL6YtLQ
# DATA UGXwjlrsqOUCC6p1ULEa5PnVbU+iBBF6u+PzJzP5rsZj5FoTxrjEonu12Mnp5/vx9cRROGM9lL4Krw8YMp6skE/uHBRvplvzUH8x
# DATA l+Fxu/5gU9zdUauwurnx7vr2g7oDvmFv7qrjOk773T6j7TccJeiBXw7yeYdjtsoEUkbT2spKfpW2TU5zmQlB4fZIvYzitzSEy6ec
# DATA O/MwSukjGddzNmV0TrOGYjo+qVFespxiZmIVZ/oS/swpW8MbK6uyxlpCC2BaOvepUMjF47Z6UEyNq+UaPaSU7DtkrwVZAgnbpHDj
# DATA ZzAIJYXcpnfWQe+RRczJg1wfVex1mgblapyRJYMrmcAVBJaiAD5Ryy3PAakvZvW+B/YVgnaIgfq5+TQ4WO9eNlnILFMxZX+78sUM
# DATA rVjz6NTj4heniCaeJoxSJwO6aCdiN+gyY6MXcCBRwuDljaTKHCWPlPNNoNXBsVGn+1z5IzGmKrZmR+7NDMkwUX2zEX1hJl0UXzOU
# DATA QFO9soiALrGb0+lUHv0Gp6wm0n4pxliVb9vQSGlgHFoizimN215TrlyuSPSSCGCmz39SVC/a7bCiyYS7l17vshojDsCHsKMgr6wy
# DATA ptJCy+umayhlizKjjtPWssScWiuUt9pxzI6jkiAYLBAvPB3xHWZafEd9DuIJdqRxIBbLoLNpK3Vyhn9yIqY24ZGTyy+jOOvCuq7Z
# DATA MtsW21yt4I58u0LGfwemK7PoNkR/h24oCDmODR5pOrGOGP7Fmgd4RhFhEH8V934cBX8Z3L516+btWbzR6xvvG7KQdkoFT44eKKL7
# DATA hXH4Q08YeK1ghAaUmzf2Ktnfi39BCVey9HUQS1J5kEBMUg6bNcth01wmx0HTPrwoYxrRtcwHtvpwZ7e18/Duzur2+haGCG3XH+7U
# DATA eWygDqGqBePYGyiL3uXCYcju6YTAmPHsHJdkyex28aKWiuWjZHrnP1kzTQ7VIi2jPxed166SZWNniAkNpGleYDIn2tqdaKkwTPRu
# DATA wHhRxnDRhUSH2rG3r+vzR8Gvl4uiznfLTAmQS5mbJCIHd6YhO9JscAeaDgSlvROsMKicSBpTRiLuyBv1Vd7If/1wXUc4+TOCpXYJ
# DATA UhHnWPaE65NkOeK4jMaTFnOKFrOFOBlXS8ReukSqPNcWkS4nJpTb7lY5S76cZGgNXpGmkehG2bddVyg5Hw9pIt6n2nDJPMDryZTL
# DATA nvd4qdc2P9gQZLtWb929v7n6/fqamC3Bp0HUxFrB+xsMn/jFscr4M1Pq39NyU6ZQTJIudFI4eTS573mKZiagIyauCzMbK6anX5vJ
# DATA jw1lCR48edvS45I7FNVNI38bHw8XyXiXVrsv7yHdy3hQaP3Ll8UpjzXqj8gClb27c2ziV2GTubiNZWZrTpZN5hWl/HsTThLK1xlH
# DATA YhXFh/7pHbyyGMEwMpYjjiC6mH4d9vvQXkDm8Mrcn7zFwmePuTpL2NXbti5oW7saS5h1/F+55SZ59F6/XngauoYcifM87XRClpkU
# DATA avSFAVwLptmD8qeCvLjl6AJa8Uw7zytPkuV16ZuW1dF06ZvN+jK7VecyxobcKvdkyroM5XEyICCp/rasPfZvWeYjrlyZhbCe/K+n
# DATA mbpmmvAUA5kBhn4J08/FjCAyDR+34uQLzkxqdxXWjYsmvHttGcmwjHzT2QBTGZ2ZDJDo6mRs68ccQV9HrqVgUFKpVPQZDh6Qvg2u
# DATA jq3gNlfU0XOG07RP8528kSCUgdLwkUNnjVwqhk9Oa6GE5Qin427kBNtgVAUfosLcVd0Zc009B/RZangbBCVHzCwwYnseKu1B52g4
# DATA nu6CuLa+XV8F/AX0gKg/2Nr9UEcB9mRw+wyaeMumoKQ6CYhgDEaI/AhvVjQgRbGdS/QZNf3gcqoiPBTpKA/SfIEc25s/MColkjSC
# DATA s2WkrT/s1e5LTftky5G69aUNdPPBynpC0YZW1/z4o6QH7vUndE/qQ+RvTVRQYTRkefHkVUSdvFxRGaWK9iBjiRg2M3kLIy9p7E4/
# DATA vupeZK6cxA4QK/dXgjpa9R+s7+zuhImtSKobZjXpqhdif5bepXdgDT9J5aa/6oqOCBlHzBOD9rhz1HsU8c2W60Kn0WA46ER3ZHZ3
# DATA Q532ZnAywLD/SLfYg5wn7QFHEURgCqC0J/tj2PbaRZXbS1PJqI7N6CBsVJ1LR5NgC9kh/s4TYHsm8IGnmoviQrk4C3hOyEmbl1f4
# DATA E8uVSZfPHnqJwKRaw4+MmdAvd47EiwV8r5iBYG0lIhNF+OgQfR31253IC1JdO5pMRtV5DVNevblAgVq+wrDMchtUxhrk1qdDStpX
# DATA S2a/LTiVp3b0qRFbVwW/IEHzcRm8CkcRhRYKMRXVJ9WgYTkzqKaKjuI9HCGqjSh/EC4uvV1ZEP+3WH0KT88wwMPV1BPTgTeeOlAH
# DATA JG6Vx8N+mnOEW9Pw8JDCcp+G3XEPc/2Sia0sdUDDkdQfPg2P20/KYDiGQosLx6SDfFLm8YY3wzO3AYqY7BxFnY+whomYOxhquPpg
# DATA DaVLQXXIU/G/BxHgAFzjddeTAbMwj6ZCISvPU53XihXBfQaFce0vZbA05hsdV4YfvbNQXSwWKx2EFSgUnRLiJ477FxUKiQa6fguZ
# DATA PIfl6geCtwGXEg8WlyiUcjxpjaJxbwh+YOHSQiyGnHa4wow35GKJa9xUWAq42tFH2776VIZoJ1xgaFmS60yx3bprfBy4fePH0tWf
# DATA AQRUXmpLbULWU+uNp+oN0Ysz9RZ0CXK/wGJpbzkeAlegu+bKFmnKWmsj6aggKWZfLGqqmBigYR6WcVMWE6CH1SUhnYx6gyjMwQ8k
# DATA W8GJube5Vr/78B4UPhYz14Mr26Qzqi2EOIGSFYTfXqh+G3nd8vLNqvif8XH+pDtCApahXD5Wo2cInZmqvpCq6nioxMkyxG9W5+G/
# DATA +hlNSnWeVcCW2zVNl+wCTZKuSVKEWQ8+O5vGjkmOKks5StwTXM3+q/EbcxiX7RhbRRSQQpJIHHQB1309uS6e4RUtrAX6cHYJfJlU
# DATA VzZTmZapB01V+edQnnanKxPkvcxWa3p1ULnNYWduSA5BYtpYaAxTjEnBq3zIj2NEw5HZaCsr48MT2K1b+EtBYraBrqDVEqvXahWN
# DATA NyuCvlttfqUQqtBsoFmCC641QqVKL2v8YkIXQb/0kDBoJnzfYSWGNr2cjCPFkssn4z7/wheBMiBq4+EFEpU6tpUjIN5SBL0w7gFe
# DATA IsscbYnM6ySOysB39DeqicQiN1hfnoI+sIFmxsyUy0C+ojSEj9a2UPslPTcMwdL0Drc9X0IU5hHyLjVTrDVF9nzoEcux9o7t/JlU
# DATA 1ROskw0qNDiynZgoBf4BggSqfWYhcT1a87Es/gOlYw2VhKntbRQAL6W48AjobtU9OR7FBS8yNtZLyg38aABx43eTT0aDWJBXqx13
# DATA ej3GRmYxvp/Vwyi0dL5ob8fCpF8TK4A+TPo5eZRi1O8l3XNMuFTTflULnB6UbEUXOBGi0srtT1GthXrVMd7pqZcI59OmmK8K+FkZ
# DATA 5+ilVG8/z6CmrAVu6wzqkMhVqrcXWXCXZ2S056IOu7NkqNpovlkvcoFeGWwro0MG0K3bF3h48YY1hzSRN/yu0zlngb8ZhJnZD8nd
# DATA 3dFLtfVsrRqbBvWvblcMJ1ylxTImEpQdIV5VPfTP8jkUCXXjFKBvaMSzhysPRSPlL+v6EwuL3obdvBsxu1l9AFcd0ResFtlNz86I
# DATA pnXFOvET6O/KizelW8X0ffL0o+iUHYgwGMsKGfMetsWzC+wdfTwnEX8SJonkKNR0SutEY6GZ3aAhAqRdKw1ylw7fV7FaWvxyh6rh
# DATA eNLWSdZsGsklNFQ2yWmwKCHqio610GLUamGXWi3Yh60W9wjWOO4dDk4QEbAAH9v9ys76vd369oNSoL+/93DLzJBOz+mfAlVQCjiH
# DATA yPWWuImdajVL0vWFZO+5C/t9kriwcwr56evQivbiBOXK8FE0GkcHvScZrp82xqyVX1ah8eXK6OjpnrgKx5jK24UpTpdqRI/O/yU4
# DATA /8PLn5x/dv7b86/Efz8PXn788hPx4Ln4+uLl/zj/LIDnLz8Rxc6/Pv/N+RfnX7785cu/F0Xh938Kzr+AX57jy1+ev6gE5/9HlHku
# DATA qnvx8hN4+/n5b6D+lx9b5QL4f2j4xfmn589Fya9e/hwa/ztR5PPzL4OVrfWyePq1qAtaen4H+vXTl/8IFYnnn4rPvxTfnoseOB1+
# DATA jh0W9Z//7vz3+DJWUHFv2aS+XVldre/stN5dWb/PE/Lvoq6vRac+E/9+AbXlGjc3+gd8+XNRnhoNzOpe/gJn5L3d3a2dsp6XUiCK
# DATA f42j+Kmo8iv+/AvxnF77WDT4S//sPYfZC8yJcqbj5c/lAP4gvn4sSsES/auYOCoGnf1Cdd+as5c/T8wZRpy03hVz1XoAQSl3wVa0
# DATA /v7Kbh2n7v+mLB4OUPT7t/BVLvtXMAPiIVDecxgvGVhwcNAJfGQMcuH2woLo+v+W1coZx+/PRcfFiBMdlrZI3XHsqEOiX5//6uXP
# DATA xdoSDc5ClgF2DycNJ/P33Ktf4Xg/Ex8Xbwff791N7ZhOi+npV9rW+ZX48Dvo509FuRcl/BWb/xII84X8/pynEQmwGoBqO67Os7th
# DATA 9KR9POqjI2Cic0ih3DWLWfxPakH0SpDqr4F47J5hY5+J2fwpNvyxKIx1iXXjV7/k5fry5S+A0t0KkEb/gCP5xfnvRDWf40y0TyZD
# DATA s5dn6UxZskH0ntIcWsgP5/8maoZlei64xIsE4/DsFF7M3yEFwk78h4xtLT7+c3D+W7EmP0Ha/hJX4gtR6itBPi/Of42/UNu/BHYm
# DATA 6voCl1dSmeBqPxdVii7Ar+I3QZSfVODQ+Naf8d+kL0SJ01fbxoL4u728jP+KP+ffpaXlxdvyGT9/e3Hp9reChW9iAk5AgyWa/Nb/
# DATA n3/Xrl1bjcYTCsWNAnbzAWGW84pq8zGp6KLHwba0ZUlXKQo0wKDd3jFeC6VSVX6nikglJp/BNUR+HsZzGIkDRpF+bz/gxyCjyyJj
# DATA VZmWzNSTU/VRcKIRiOlzVCELmbJCupKWLNNQix7GpQAvBqwrFhL1II77hesgX5cQ5JLDMg/avT5cf5jX1UJxoH8GrEawjJ8gW5Es
# DATA Zasu5GlgYIJ1vXj5d8y0gOMxy2GxBs5c5L9fQ0FxwJDkY4lCL5BniSY+gapEqS/whHweusjkhtwqBl9ohDwS8OSDsUAiP0iNVYMh
# DATA iTtPezSB0QxPJvCQbHYK1fiW4TiCONKkXu8Mu1lZxJwZ8iApVwjjSLoDagpsjdq9ceFoGE8YzkH/VKLkMebSxbVQedSR/5J8k80W
# DATA 4m3w7uo9ohgbvPMZVRZZ6yEqNhDT8VpkvWrHWIMbWAfx8sQBNyLgKvwe7g32xnsL4VRNJ8n9KD8AkfBJJ8U0cTIHKBOBDAZSKUth
# DATA 4ghHsfvFy58BMYCc9im+IqgkmWd4ZCAJwKiSIeCLC0vLwXX8Z2qH/yNJe3zCMgWrzsNJLjsvxlaW0hsKRC9MCU0c3f8AMlrwoHdX
# DATA pXrbFhdv9CUK4qHLjmDpo789AQcTcK8GJ9STmDFLJYotmBCAhiqKAFpE6GKN8RP4QYqndMPfPwW9eVEttPWUwkGYD4RPbi18B21a
# DATA gyF4CsAn9G6IBmiZ+PbtZXRRQUahmpWj2hS17Ozcl/EacdDFjEWIadmLMSYdvG0mjJt+R2wT0LaIhRz8OBoPJao9hWdwedqxKmHR
# DATA ftgdRjHFt5vbJpSuhFNHAntHfNObzx5LNrqI7y/JKb1kBILXb4AtAhU5Iu6vYS8AbdHF6Hm28+NV1K/4AMwD7nLPWVGwuJCeMzQp
# DATA WL/JsFfbbHKVa3X5dZphreyrJFwnQFCm6xrcGD+FU8qYUcENxJPneJN4nhDxc3DKb6QXnFCIZIm4TyQA4gPY1Sz5gb/TEfljaSd6
# DATA M4B1kmH4cbA/nBwF2zsruGHrq2s7K3fEAcUpUo7ByQ5/PR52T/o9xEwx2NXoZL/f6wCibYIIxE+CjVn04OM3zMw8NY3k6+InSU+j
# DATA NqS6ICtqHFdlnZJfapddo3Nv1JxGMnflvyeu9PrcgONALMPXQvb5BIWdT6SKCfVePqHn5U+lJyNYPb0TpXcLGqi7ZGx35qrSjUCQ
# DATA KSRS2Yi6KlgMFrk1GbZiUXDQjQvYoEwOVaPkUItNSD0oCaMyGD4uSNqonEw6xQp8E704HhWm8C6U974IUH31Oc0C35R9gh9cef8R
# DATA Lr1fkZbw+cu/x5u9uPbbWXA8Z6AKwxidThe4DANSmuylj9WLiXG8nBFYhCSGhBMWMR9CHbHCwzEK50bwOf9fNHUoMv0aOxU7shdy
# DATA FCV7GUKW0piICf5Y0PCXqFz4PEx03eNV6/OjNV5IeNLCnAFdF0LIkdQ5EidOZRQdkxmm9wgSNsJXFlD6XZ2PyPSiwFoMIwTlIZSt
# DATA zsPPFvTGTHlqz/8f6ow+w8P1M0vQAwHQlmdNkdCdU/H67/Fyo2YV5URDnhUDlAjZI0s+o14n42491gcbHw4ESDFBPxZ7HieJOIMz
# DATA 5vZkeNzrcFvuxKl6LJMCWxHyNyuG5gZuZq2SgViHdcUpcWcjGQrGWYxs0ksPxkwMe+SM043jsguja48sL5PhyMSXhCoHSXH4gi72
# DATA CagNR7DHaxi/Rs7nCEN70HtSCyuTflwOPauJcLnDuHLQBc5fMBsJH++HaJ8RLD1qH7tZk+AZ2/8SAzNKHPRP4iMnkA7ai08HnYIs
# DATA I8YwGBaMeOhhrLzaadExTJz2JcT69Y0hIHdDiTF1rZhHK9i0uHAcTY6G3RIjCTgIbGaKaipgxWfJTNTGjRCeJC+Ft29+e9nzM/Cz
# DATA 4L8FC8OFt9/O4rFrGztmn6uCF4ij/LfKZmBc/YCbrm+sK8YRoKpdmhyQLdwWdyoHc8pUJVUIq4Q99jSklMTQMl8l1gEn/eCwEDa6
# DATA g7i5Nwhv4DANJwe5XlEfMxJDEgTl/SneUa5u0fi4N6Hg9cJT+KXV6Q9Pugf9NljGRz0yHocYck/rRsZ8VYgTvtC7h50hvcZvqaVL
# DATA eVWmAKB+UsIBtxPRMSe58XQOxEAjEYE5GqNaJQ8ZLYHkp0obyZYfoVeHmFFgcfxlzF9U/gaqpEIJ26eEQ53/CxCHsn8SFYnj4uXP
# DATA SID/Eu2leP78iu0IX/GFTtBgWanPnpNBEIqEDjKYCfcmx8oAN7lFin9Fkv7s/HeiMTD8fKztWD/FA8/YDFb7zO4uEoRjsV2qDYJc
# DATA Kz8a9gaFg/DpR2dghn4Efu7k0VGypl9md6ggrB7mXmVeAz7bhtSGFFQKJNvJIQj6lHA2FYMxyfYhxFaMEEojMeQ4NKABKzf2ys0b
# DATA 39NPKiZ4YPPpUgkSR2Jt08WXNJUtbRrN048EZ0A34ZBDDKi34Q3890aI0QRI9XIgZppQXO1+rNEh7TNXV54oLj/OP2qP5/u9fZ0K
# DATA dl48nrfkwrRChqwo88QoLkpN35ArdQNDKMIb4rUbYTKSwg7EMvLOuNoOY2yi5pjU0fm1J46rVXCjhizlBnAxom6stpi3u+WpiXMM
# DATA XyDzrmGGmUjvctojcJsby1QvYiNg7TpFm4eEdR6Nduc4KjeIeJsNhXgJYDtc4XRe4xCt4DroOfB7uCd+gszu9xaz4z6RWECdTUZo
# DATA a402lsjUaM+wmRQPRCPub/CK+iJYWX1QV+reGG3H4jAbRR1xQYRE9qgzeRJ1djCpyd+eDMFNMACdSRddBjsT0s3ER1G/L38n/YkQ
# DATA BNsjOsVwIDrKcG8PaGhP/IVG7OE1enjNfPYWPHvrLe6hQR+UnIg7zP+GxXlJCzdCGYZnJ8gMGw8HvYmQNdaMgILtyDak7d7fMe/I
# DATA e4OVAyHL1DhmqjwEETFiR7WAA465tb3BB204LbxlkTdZneHIFtGfXfDHF0JSfDQU5R4+aMcf1RaEdLc3ULNfuyYYHc3pjfDaHiiJ
# DATA +KC6vbx8gQnCzZNreuTEGJMi9pWYtHYfxtTYhZrEW5uD1baQw7vtce16WfxfsHCztHirurBQBT5lDX1bEJY4N38cddeifvt0J+rU
# DATA bt6GUluglI/hMlCbiDMW618ny2aTZjfq3j2tYedjNbHOXHgiTC4UXJIrrkSiMVBAyAhVeqacoaACMIwBEEJIvTc5UtGOYynJGi6f
# DATA DSMiwtRKi6+sN7RcQulUx3gQyvRlRVvEDLangq/gIw7azHUwSgZT3FDWuOSPUqbl8MOazKybLGlx/pMxTor7FiitRv4IDcerU024
# DATA 4Q3sarvaFWldblcsfVe7ghqvth0LDX0yXUkTXr+jU8v3WKrqpjdjenzP1qZBQkbTxg20XZHCoKiZb6HtiilC+yt2AjxJ0DRHwqKm
# DATA Wf+Fh0HkXbUSs8K8qUNbfKST0Odvy3CMBrQxeQpXCJgweVdMIRned7Yk+mbw/SgaoaVSIgAF8ijGGzfkdB50+ieAdh2AZ8b+cBLG
# DATA QR/i+flCEleSWbIb4aQvYzF5W1aNybR2M8VM8qBMY3hFCwVF3vJWWdiXZhk7XSIdBDxNFoyjX9lEgq6RhHfSjz35vFl+AT8lgjwz
# DATA RoKyi/Ur9NmHkuSVWci88PXLn9H18eU/k2MGXjDROA8XTHEyOylgyJtbNNmwOtMs3jF/gp40c3hjT3GS9nspw9GdcFi2FCMXcmIG
# DATA 6/uPCPIDE3iyioxEMvHyox5cVwx+oFPOSQyPKOgPDyuO53t4/m+GY4uY0aq4QBnugQhqp3NPRm5idNbthqZLDPv9oYvN+sZ6STtU
# DATA iP9nczsEvsJAakYqrXTfxcU/b0+/FPe3g8etw5P2uPsKvQCz/f8Wl27dXrL9/xYXbi4uvPb/+4b8/3YjsG23x70+QCbEYGiBvJGM
# DATA 5PPw3Q+EFIvZVPk4KpH+vTegpKNgiRhTguHTLBfAg85g0p/B3y8+Opn01AsUdjKbByB/B/QfqeBChx0KlJriN0duf37vOHH4O45y
# DATA y7eyvS6iwaPa0+vXh3GFAwTF+Xp/tbVyHz3PVw2F71Q/u23yaDTOMfAR+w1ZNV9+DLdtHUjwQtrcMKpB/Pef4KF4RSzrncDDTw+E
# DATA 0PUYkJ7OPwUfGXTL/+nLX4ZTffjEnLWM41Dmg5Agfkc9NFMak7yFthsLn8rGymXrNbxZedwWDFpO9q3lhTyQlPTmBJTVA+hRMR2S
# DATA 39PI4kICqN7o/C6Vqj8Z2XhvurKPev2+C8WoW8kyp9mGNLplagWTtOOkaqeT9JGtnwZTLFpfP0EdOpDDlyrORpCJtnBfwpInjhmv
# DATA JQ+MamT+NuvHEeez9v15GfvG0f5wOGlJdloQ01ZiFVlnIq5HYpMJiWYI6d9rrHJJqH7LMNeyBpCATga9SS1VQZN4ERFWtSpLUx61
# DATA eyW094Xlh5GTArn9XO4Vx+3xR6hZp5cIPIUwJ0LWPO4i3pyY7jI6eP1ouC82uBg0oNuNho/FS/1hHMP09XsfRVJRKe5ik3F7EPfg
# DATA 2MOLpat5FLN4ebUjcwJYulKaigwXCjehc3qLbohZkzpE6I9SFVo52yHTQ7dHWTknR3X0o6jJBBk0g0VKa7Q3SNUb2jWamkOAZeNZ
# DATA EZVcCzhnqjgL2/v9yNAybg3jSW3+JB7P7/cG8+PjoHwQJLphNZOmokNgpfIJXIAMNZ2hrUSPeGNDhZRCW5A9XPWlSixRiroc0l6q
# DATA YJ5ra52ol5B4AYUm2ar05+GjjGJlq0ycU1gBCuVRVx6QpYBif0XXOAwhEtMn7uH87fFRr3NUI5mpgl9KUiozE0eJ1wmbD7MPkTTE
# DATA RynWJn6UnwDG0D7TCWn34LEohC0UQvHFNjOIB4kTnCu0j3p2aK7RXCOfk4AzzaQ/Hv5QQVe+GI4DSuVxEkNeaZpyy0KR0S73M6NG
# DATA T30+3vYfPpGKHZ++5qDe37CPlOBpd6T0bES1/YFCas+/4jmUthA1vfygLObIKiKI0i0kHtkrIStjDYkqNWVYHCjocG3pKP0pDotE
# DATA S/UQHDfd+FyaC+X4kRxItxe3x8ct4L/gQcGkikRnn4FF3yHIoM9iMwaoafMcfV70T2b9K4LHyPplKjGQLUDnBioMKQRXgpUA5DjB
# DATA wSTO6BhwS9GPF1QV/aDHDvgGy+i6oLGdYb/POEXlMp7G2Dfi7eWyYD9EczVEVtSMTvyGJwwk5hgJ6jmtrXQ6J+N2B20Xi6Ato42j
# DATA s1FLTtUsepNPyJ1mvAALYbwxbf8kZBtDo4mdFfe+YzFfj4+iAcO1c/BYu9c3NJf+zti9N02qGVwi5y5OI3m9bdEtnL2QfyI27wuI
# DATA Iv3Upu3zz+4E5J+EPs2fSwtsqgiD/IB/kA+/hirATApO0egBacG5qp1RKNrzZR5JDMGFewCA3pRN55VDneUE9PK+y7QUwh1CXLBr
# DATA qkfbdQCKXqtv58LQ4mpoSHGFvzYWq00F6SSfVReboHYFnPqwSXpE83eTZcpamWVSsBhXs9B0zObTRF/t9Pb8/Ffo4A5UlLSMf6G0
# DATA /MWEG184L5bdEdDBh6DSH3Y+StzLwBEekUAGfIMU3zZbq9v1ld3gGX3ZXvtgW37e2Hx38/79zQ8sSYXw74XYOD4ZAaKMhPk4GMPt
# DATA xXFsRbR5B0NkfWPXhBDJhhRJwopIIH39Rmv93oartP1+dLo/FOLRuuxpoZiNbDJTr/xAJ8assOF7+rUUlsmYM1CAidumeFiA/5T4
# DATA CeCTtOo/yNBMJ2RBjet1eQtDYjIzMFdCJcSggCP+h+Gsd9L539cIKvDyZxhxQ7zSr40KbbOHuZ0Mw8ds9owMzBi/ycFsVRkdTNsF
# DATA BvP+I6rVfp6qQ/MMUEoU4R+bjYFSvZTbh+CK+IpMAJn6/8WFW7eXb7r6/7cXXsf/fyN/b76hLt6QgXp0OjkaDm7OXbt27T6n7oZc
# DATA OkQl0kmtAvuEU31TGm/MEYCoapAZYDw8OTxCiVBJzbkNA0ftGAwC6utxu0OWAsBPQT0GHDn0I+h9AeBkG2KC48l7gjX2rwJeQIiQ
# DATA 6jO4Wk2o2XTjA/AMy9qAjZ2M+6Ktyph6J9vkzpbgZzg45lQHiPcYrWiHB4T49f7CqOFzlJ0aDepsr2+hq7+Q5IwsA3Or99fhxoRr
# DATA jrnZSeUiJYxwbnVzY1cIYvVtgKza3d68j8VtMQSUqeNhP5zbqW+/v75at+9gjPWGFKPUiHMPN9Z3W9ubm7tatvE5i81tPdyGJBiQ
# DATA yjOlzvKjRdHy7sq9+g6GSKEWg/OjdIePB6jIwUgpStPIaK6UNyLk5Jin/AI4c/QGYikZ+7V3IH/pCHIeiBeKcw9WftC6v3mvdffD
# DATA XWzSCJtXaltKwjQeHoq5jjm/zFiutCAogCJEPPhSED3S4TFiV2xB+GR8FOyDiU3sIzEPIyoTlzg/hpRLpRgd4zW5/ThgMpSR4LDH
# DATA 6P5GFFcDpWarBzkT8QEro+jKbaeosDKRoocLbB8FPM0rPs9qEyMhH2tn2IVDtCezWMtOSP2DLpSmsDHqO4xkIDQvNGSxhznRaXE4
# DATA CxWtOsGxwxUz6iY1Nw+RbpL5ce5t13d2bLHbGTBlGZHriioFOS4na+VgCGoxjACF/xQ8929ZjTXD2mrAkg8AiG8MJ+8COTjRZEYF
# DATA T0OcJfTPodwU+C+qU6PuCkBlix7BjRopCQDJEWucoVxiA5Fd7JNHvSHq4mQDDa69qdAL4CXBLMSWijCRC/AgQaix1IYA/h55NQmC
# DATA BfOh9oWCjfdYyJexQiqgNa2AAflJAVuCCFrrqexUMTn6hjGKZkMWBNen4/aTwkIJl6LsjkXPTLOYqLJCnIX6UuMZtV+riVo5FTxs
# DATA Y1xDcEqDEIW9JwsL5b0niwd7T94+EB++c9DkpGNYtijuoEsLzTl7ELww0O+C5+mNoPE0bOt1xJoAjZ6YCBUU3/Hfs2axUV5arrpt
# DATA cB4/GLRoRlQ058t9h1kB+R2fTyvV4nI38u+qOgwnyQtsx3gsl9DU+pOlevfL9A3q8Dxjo9o3DHWnMD2spDdVMb2P/p2OZCueO1Ts
# DATA 7CelvRj1I4620hM2OkK0cfb+5CIhTzCc8pTiWnXEZr1JrpqwcgNoP/iGZ7J4PmTF0ERzsZt7FXUEcvvBIc1VWpvS9d8DyFNi6oJz
# DATA 67fxti4f07w1cN6qTW+iQz0F6I5S4O0enxwXVKUNrLCZWbdgDoWpPKKYTNaJzhmqE7Vgoep1+XDXinNp9dGkCJYX5TPX7cWjfvs0
# DATA aGNEXRtSHATXFgIGG7hWcf0PsknW8ApMJIMVoqpByvrwSBCoPEjWYa4g8xGS9Y1gUf6wKqYe+E4/GhRoXn2JMJB0dyaYmMIqy6nf
# DATA mPzxgo1NuImRonGH+NviwoLnHSIA6tx1LDNvtuJ2KTaORWPL6MeUxUIyy6qfhTqVRv32KIZMIbha4iWLKgtGOweCHOIjaojkocdA
# DATA hN6e4PFVTIwAIsKPoSPbkrqMduUj87hPHilngp13+oIULHnIcLKUymJBLMT4JcJHf3jITJ89HfjMhayjkOzHk9NSchXMHJHMqpg3
# DATA unJ9gI73CsFLVKdryZHObLYEZiwDmllbVPj9QdevXv1ge3Pj/odSp2opW+s/WL2fqWxNIBQoUQz4ZDLPZNVlrKo8BOVC5+GWYEWf
# DATA uUulF69CcEUy7FI9tlJ0kt+v/oWCxz2AA7KMlYI2DRVBzEinD0mAD7quH5TBpbRq9aDLcf1JumwhdRfoAsR3K4jzmOggUL4ckbRT
# DATA CBsgI1Bmusn4AE/w8K0Py28dl9/q7r71XvWtB9W3dv4mJNe+yuExnfEoRjTRK4HuIZB0Cr5RU+QlEaqI2vBkclD+NkSjwsjjWshu
# DATA HlIG4T5Jz6PksBiNiSktMvanTTS5qHJla6u+seaSYqqDlZpu0KhST6uuA3zK/IeM5Ey2IQnPrZTTkI5KeXbQj8W8NYsbOIRJAuIe
# DATA XJmyKcxgYpS5TaJbJViZ3BapU4yTk8oJmQF+szPFGwR+svgs86vsqTHFWZohqTQxRofubtric0Wc3bqHg0bl4cbK+2IaVu7er4ep
# DATA LFj2Jbk000xf22vmLpB0r79vIDR8PkfDsYQVwaAne5WPBQ9gCCT0GwTMDCrn8Rt0nFAqO631ne36vYKsRGJtpEax5JhFfQM4GXTa
# DATA dNEw62eoD0uxZRvlqPdxFH0kBZrE+2X7fWeIoJ6qyXrgtlGwS3toNNWAkz1iCgbGFxWGgxy3WRP0R/wXjMkTdHor7CPPbizRhUWV
# DATA aFSh2FhIbV0uAgIwFQLXb66HwcPSWX1Gb6JBl28yMMmQr7UwDsvwB4waEA2C5nXGdg++X/8QfwrJ81zP83502BsMUiq6W7+3vpG7
# DATA KkAvoD7BkY+AHrp2UL7hj+RpIeSC7+pf5TOHXnmiwsZ2fW1ldbe+Fhh9aOIZLEo0uF7Adiqy+kJcfwSPijWmlbXn+VcJCJW8x1oG
# DATA Lbq9NigdiLx+z6oAUNcnM3txLXgqW6TclyXFGTmzqfzqyVjHYg4l8zN4qnwkL/2gVYamMAWh/LFy2B/uF8LrUqnRqN5eBn0RFlKl
# DATA vC3HQkJJvH1zSUOHUZMgfnLjGdoEBHGxVQn4ToLVGWZWfIeuPIYYj8e6h98Z8w1uJGTWwCoaxuvNYvHKL8oHVm56QxrvRVlT4j2Q
# DATA fCmHL3Q8XeaISjt1Us+rjGOI8TkmvcFJNOcJdDGSQKfz/5zs07wdEVoq0mYFmDPciwS3++FefL3wTjV6AsaxvfhG8Z0CQ8K0mgZ6
# DATA TPN6URSsQeHK9eJf2HmfwVhTeVCs+nU+mrMS93kGdPJYkPoz5CvPWMp7pgMjnwHG0jsfRafP4MgEJRnELD+L2/3Js26M0AEwmMZi
# DATA E1teT5llucWo8FLT8HjDJNd71/bCsOh9VXQcFCJYQzH4y1qwXE0NUHJ4Kr3j7qmEIJnYMFQNoogMQZtReEr9R/Qn/AQ/MXf38AVi
# DATA A3gAOV0/Q8zIWh/y2zPSC93ojb1I5w38o3zqqa2ScQg1ZQwKH+NShV94p3dcLLRPJkdii/8YVYmCUBrVWpOIa18QQDR+Jhay1ykC
# DATA je3tACbNONxbNOo2D1W3hZDbEJU1rgme9c7evkWc4vlOfXW7vvtsa2Vn54PN7bVnmDXlGR+brXfEuflMFFirb+yur9x/trK1Ts9W
# DATA Hu6+t7m9/jcrkF2o6FbKjanBFBs/3BvvDZo3wnC2AUwXKhp78d5O8/o7otVposyzvyiGpVThIKsbe/vR6V8ZgzQhoNK+74c2DWTV
# DATA XwBYHvF6k/8VddyolJvXq/PzMHXx/PeqzRtV+tS88b3EHH4vu/dPFvf3Go2F8jvN642gPC/++73yf5fWosR7EtKrc9QetzsQYI3A
# DATA POqb2E9YEhSk5kOIj5iEILcJJqXfxs10cykgH0frhzdqweLS21kiqxLo1vi6GHDqy5iivtvxhJDcK8HuUaQUtpbqjjSV4DlCWO3o
# DATA VlEBGD6WB20ttbz5iauw/EgJcCekG4Y3AHJEdhYeyc9nfLntA2LvpKUcUVrsp1LQFvhtMoIHxycT8D4O7uMriEFfgn4OBDuaYIfB
# DATA e4KcBMTX9oSA54NJ+9AwvY+GcY+vyjrak0Se7fqDjZVVyNy0Xd/a3Fnf3dz+kNLrTibH7cG8Qr0pq+669rNUbDRB5/POd6BN1Z18
# DATA RvHt+v36yk5dRXtKsx47rRS04imU+YzESVc5FFLJyT641M5ji/NPdcNn89IzaJ7W4h3l1tFC143aU9dL/8xwgiecsrj2NFzpwDkE
# DATA ahFw4ICAFMBHfTTocvM3UKItQQJ0UW95lQ2EVRDIyx14FnpidMOHggrLK4ecXlovgXmPCM/oTcPxk713CsrJw0iZAULYOIpHw0Ec
# DATA JW6g/JxkoqVbt9mTBK6Yaq3h+BPFwSquS1xoAXHmbTQTqNgkKuMYVilqAfXyIhQjtgKOEathVI/2ISq1NCUXnFZFCT762VfEIfNH
# DATA e13B0+V/gE+2D51ozbHdZnfcPgBbSy/G+jBDZaLQSJzoMsOzVfIiA+e8DjAW8EK3wr74GTMkWZLEm2rKSpgCkX9WrEkRRy7+W3xH
# DATA TI9Z85RBvF/f3hFSg1K+jfHePTkRrLtw3B4BoirXJ0HPISGWRkkanBbgJaDTxeW3l7998/by22TJgKfiJMIqL9IXnjvq0o2gsFAq
# DATA in1QWA7KuDuoXh02a7nTVDMtNv5rl9enGzXh4xRAYdb4cYAwbmfAzr1l7WLElZaourmmYWcX8vkxVbH8b+xeC5HfTzT5N6/ZFk84
# DATA 1sHTyp4UM1EqKKWRnz98uL7Gr6J4gR9z7qy/fljf2U3vVywejUw3lJaMmD8Wp478xrliFRRwdYr3GztAeJzA5gzcbfHdNpGJMWfp
# DATA nvIrxB9u7Ky8W29trey+F1o9ymfXlIUTVs2kV5+eM0VJerIMaFZ6htpjFw1Ll08HxDKIRFVVQjWVa8k0GlKfGwtNR+lHwaJoljOz
# DATA bKs3isTXV7a2WnSVQrHah/EFns61gEbC8FmmPkkpaqyxGSEUoIewVa4/1K3W4ApxAAifT28vn0lNA2sYkkOSigCEyaU8QAaALLMR
# DATA Kg1615tLmUT0YH1nZ33jnpwAPpVBSwGYr8ftTmUQPebqFPxvKWCv25J0v67ER20heaA01u0dguhX9PiOpdN9SYjvpHStUvNnDoq3
# DATA rAhoqmBu3GIijwGvkCH1xSaCILsYK2TwhgQcBPdADNXWKwfOK4g6xo7sgpMwJmAhfDTsnxxH4AjcsFwElXdkA18nVRR+guRNVGPv
# DATA wKtcKRhbAEsyc6Y8TvBAykgImoiuXwkHbGAxeWtXCpSkG7fsrDzIq2FRSCVLzWLT0PSobShW73QEF69wvzcwIR4JEI6ZTVEDPlaT
# DATA TbJ7dQviBMTvwKrO5nzeC6aXARwVDdmRpi9606J3bqr1YPPhxi40/O799dVdTzI0rt4x3OHqSb2XbNVH6fbRIhGBjQbklKDe3fSS
# DATA Vvkp0vKQp7wIO4h9+qokl4JPO7oIilXpdRGOgJ0sq2jOnTXvEy8d592WlQQhamL561kS8BUAd6Nuiw9SI5e8tEcXU1EtOGC7MAXz
# DATA FZQE4ooPhA0pf4MC8RfUG0i3Tolu4WLhOoAUScDbuAeKCRPjVgXAcPBLUL6LpndjaBRd4RsXOoJQRCy+ZM4O/IQ6jkSnALwDmh4O
# DATA yuyZsDfgZwhLa8Px5se68JGujryYDzhgo8TB5+7SJlJHamyBJFRGifAjDBEk+3WFoRGWy4PhY/GBezNzTWOaqdQa5KUAAVKEBAs6
# DATA +ckpC4yG5GJogAAAFzDP+sCxTlXeU8EL8VC7I+kOYjrb3WAC2DF0rEZtcWTjdCsdUKqIqRIPpB+cGWkILFFTyqaXEjAltia15WFU
# DATA Oi5DS48m2GumYCaf8YyLcyAy5cYscY07dnMp+G7NFoBqwfLCd24rzPIjbVNg3SjhGO+NEWIH9UHgnh82i39EcpNM2ZCUkZSPJmqk
# DATA qiomu9XqiR3baoku9A/ItmxGLIuHlXSyU0X0FUe/Yd5zVHMocmFbSUd44x5h1umee0Zl7UcR9zuhmrCmJas+fteJT9Ah66Qv7Sb7
# DATA jAbtmttr1+LOadkdb/eeDO1i6FkQAsBLmyKc2PAfKLs5lRKsVfbGDz9hEd7G5m5rfUNcxO+DN5huWqqJqOZGyN89MB2JEnpawKGL
# DATA CUaqKcENwLwPT48XU7hz4EzvyzglL5g4sUQ5CR+AzBixK/B0kvaBQC6L1N+6IVtiSsIMUOKkfmPEwUApirhQXfaWliH9CBTP57rl
# DATA V3e4k5q62wohNIXjw6Vxw1z8k89T8aoXwOlY9iowHVtuiGqTGr6Imq7RlyW51TWQpxM5W+lj4gij2qLldw0JccixAKpwHJlcJw/4
# DATA A7C4fGsDVTeEuI4hXf4V4lUSddpxQBjmKObsJMILmAx4pAueEX8UlPW7ZiDBAige315aSIlTgXc47g1brMn4SfbFqAkK3a1vbz/c
# DATA 2rU4k+oyjkzUQrDjQoKqqn4AUriZWMAkPDEUM6kBD1fdO9AedgiqmdABGJ8eIOnvmgqYsoyLIw5OoTU/M46rZHg1M9HOUXuQ5J6o
# DATA M0YCQGQPMiGAwrjdIUwcL4eRP6LO1GCcacFcWXLd1ho4CNx9uPNhwv/z1BdIRd7DyWFWAPHySIhvvR9H5g6kcRd9i+GrZQ3/SXPp
# DATA TB+I4epMPp3ko2xu+hY5G9JyEGdWtKQOuVlPNh2qqoKL5f1CoiwZVw4hsx+O290ox9mezuGR4Xg5lRgaKiHM+aeBColi+LjV7cWI
# DATA W2ZBLSUGAiGEsp/ILqBBIq3j9kBU1yWbFxLr1HFsrdyrtx6s39tGFxMczvq2xRNS9wB8TdkB9NMrpX/2Js99ck7fPIY60BfDnRKf
# DATA kzx7axlnr/dlzTLx4FZf0726ZhY5HAYh258+sAscWHYFzqn13YxTa6b1z39iKEc2V/6igwIC6ijMXq9D1WQ9xuJWtbCt9XV6VsxY
# DATA RGNOXL2bvSc9EdtOfo1Uik1RpRAWYyZSIevUygjzBmCABoChCc1xaEnZfi2keE+BGGrVFlWofmD0pQftJ6AEAxqAAq56Dl+6C8of
# DATA VMqltscgdXCqaLGvxNIpZMqKxtw+POh1Q8loxSMQHdR5YmmXLEcPH7EVLohVZRHeFMFMXBe3d1sqgojlpVoy1GnO7+6pTpacorqn
# DATA 4Dgs882n3Hx68/bZHhf0RXXNQMIpW9wasBNoIoOhAKDWFhZgkS1Z4YICwpXfCGdizRc+xJxDuVidcsFMHmN57o5k9E+AGIB+hJle
# DATA mghqPQb3QEctJWPaCjmptOhW2OqMI45+QolkOrOk6DxEQtEBf8Z+gdw27IaYb0MkqdvuF7AUPwtoqGtQk1GdxPeiRyBJjTDETSP3
# DATA bs2cPn1yKbhvYwkNUaPov/ZdseiqZl/Lr3IOdF+aPjnkSiTeS0m+V36PuJT45js8lBh2GZ5MjlGeCFeVNp4AWxur99f12JLpV+nE
# DATA lapKxLUBn9CwmbGa6A/BFdNaptWLe9JULqjPTf9J6MhG1ynpi18mOAWHApigbm9QM95cq7+/8fD+ffwF5AK5/yjflPrqEyHeXlxY
# DATA 8MvgGdt6dfPB1v36Lp789tbORw8aWkbKEzpT+oxxVBeTcHoHJhP0kxMHyBNMwPQpkuHy4rMUQS4kWOF+39yq8373ChzMmQxQj6YH
# DATA DyjHHrOsLScJfWamWt2P/eO5aKWAjKBu8PaCm7gG8wG0SLvJ4yR1vb1/ksDrCZ07i1N2JfbUtDGpYW2KsbcXMzq6fVmBLjT1TrpV
# DATA NDImITiPV+kGLSYJDvB5ukIMCuhWoAF6+lFb9BDgzPbHw8cxJCdmrQVAzwAFTKL+acXPLdPUIakX/vQfc1lZ0gU3izw8lhgxXcbS
# DATA VzPdSKxdxLD17J2SQ4sM2ny5bWoGoRaz28QhoxXRPp2SeZxOxmOOPIR3tFlwxhDRYlq1Xl3y9euc8zJsPxKDRzeHqnqJXcvZuUZ1
# DATA SbvdcMHkRVbhmolCLgibIWPRpJyZZr+OvPdAsik3VI4MzPcT1EZ2Zkzk2GoVeoNB5AvKxecYJ8pwB+QqLR2tXRsu44AiYHkpCUJu
# DATA Aea4IDkwoTc8cotXdHcRtnU/HZxt0VoBMaVgbki4MH7fuFvM1Ip5BXaZhwwaFqLW+maKlsmev8zTzZpmi+o8nUrebngtn6DPANZV
# DATA Cq63/AGuuqmZe8zt38f7pXWgKS299HVI3r3plxa68peMm7iOpUBHk1Lq1fziWucUtcs09uo3ZE/T5VoaikvpMy9oac/qYGrnpqEL
# DATA XmgAyrGJVh3ceeRquww7X1PgPrFR/6C+7TT0ZrA5iBSmLgoaPxqKgbb7wI/jk4ODXqeHjl0Q1ydjFCFEC7QOMCttcYE76sUIapMI
# DATA RTeBukyOx+gKCo9SwixU8/MwJnYLpqsBLlAGymWxWsYnXHszNQT88she2QhfOe8MKfVmKN2V5ytdmHyKdOn6qrXtrj8rsx7/mC6k
# DATA iE+VRL4Z9Xuaqjuhkvc7wJRS1fBTdfbfjGre1Mr/sajgc8m4V6mQn+K8BAHnVqGZ1PCZBHxVyndD734Rjburt0470S/td5YLmzxD
# DATA Z90bHAx9mnkOK82CC9eRSIQAlLuO+GhGPTf8bpoQfNr1KSRXvBLFOfaCtefTSfiKFectv43eUGsSlR1Wc6rjUNOkVew8ZVGXmC+r
# DATA 1bE39qmEbmBA+jVjpv3nN0WpuVmjDRCBzc1djsexuKguwYLYX23etc5JE4cAg5hb6xvvbrbeFRuc6wPKLqbGk3gqqG/sbn9o1oCE
# DATA 7ThwOctEZzosks7hMDfT/d/en3YOBoP49MjNXBHn/64T91Bun09f/hzzcn0MXy0PhpR7kUwJWMuAmcileCblthAAoH9lGZbu6MpV
# DATA 5U2MKKxBVGGekJ+pGmukZVZX42ffWfudNFW1BhnQpkSkn5TS6Jne1TABDeIFaoP4kZCUOzS97q8czHOkaD249r5MTKOX6an6eFbl
# DATA xDZPZYVnKsRDvMK/+Tfw2d7gmgoBSO+HL6u0cTAlBhR8V1+FvO0WZ3L1kRsTLkjb9ZW1D8NZujLTtewC1zPLwZ6pQC2OZpVv1PTq
# DATA XdDRyQRp8LSObCoRZQNCgfpl2s3ows2/GdwlrTK0Ryl2ERf/uH0K1y3MuNQOBhHgxo8oS4zOs1SZm6qdVfTME1rz05VU0chSkgyU
# DATA sIvVpbPBV8Sd/0UzYyvHGmSVq0KuTsgz99n5ly9/EdBJKntN6WDy8V19g9lvC8mqZBxdhhVTAjz6ubFpHPym2HIqPbvbFbaQf9ln
# DATA ImjG5mg9WN95sLK7+l54mVXmxEqwyP92/qtkttTfYaZUSKf3D5RCMJyyqFOva3lMntNEPcfsmi3k+atO1flQu55sJ0mnn+xURMWp
# DATA 1bvZc5z8D0YaHddhc3o6nWz/Ar9lwE40AiFxZo4ib6/PUsTlCxh2MrVRr9QI/iaipPHVgzBkIIgwQA17N9g/pRjT0bA3mFSCLTEJ
# DATA EEgcbKGiZX4QTeCS7amVlQ0QnTos4f1GtBF0hiPIa6YUnd1e+3AwjCe9DqgwJ0M6XzoyLfqFTPYp9viWCWGfXw1qbIeppq8L86IE
# DATA +ZNvM7dMOBz6UMoVXp/C075KZWwyadncVdJzgpZRcU2LggH4Ox/u7NYftLZWVr8PGVOkZ5O4CG493A2zRurNm2rsgVU8ebbsbTDo
# DATA EgE4Rvq3b2W1hPM/LWOrcUzJhK186/UqrC6k3uOJcwPenEToF/MPySVBwXVKKt6Pe7GYhEMb/CehUkotrXLADHpPdhB/sWDmuKzs
# DATA HlFKxMMHvSfrg5KVALOCLyGvoldlegAEBmhN8NXYVM6ANhCsPbzjXBcXcRoMKBq8FLS7Xd7v8clI9AojQdSLRc87gN7Ct9PCrYRN
# DATA 0lO3go8SfS9gzD33haaE84cW/GlFi2beAWKHx6JOUQ2rOhPmVWsTEiLBqH8qY8nEFighhpjz1v6we2rjamAhdeP02COiQbclcQUL
# DATA UCqtEIEpFsJVgtAsAyCGzIgpARU9SkpPBRbEYgkhFhFtIczb9P1ocDiREjcYs2Dcrr8pvq7fjn2jf4yGaRIxsA5ryo9w8dLozwyM
# DATA zyYqEw5Ai2eE25AHed5nikZYARBN2+OoxWgB2BseLeMjmKDEBJEg/nMXAYnx5oMtFNMtu3juIeUtL9wEAUuat8J3N7fvrq+t1TfC
# DATA sxwqXnm7kNlIwUfzXn2XvG3xF1IzQ75YkiPCbHu47tgSYJrRvLEvnD9ENkf7lI4gBsGnEM6DkptC++dT/WyzeqO02FA1WWGdOptX
# DATA 29PDKLWjEp0xpT/0ZlPCO81n44ITfiLcDpdeXQRZ+pxi84h+Tp8WLj6NRHAczTt7byiU/JKtW+7IFAV7Idr3RB7n7NnW5s5lu9ZH
# DATA jqwozGBCLUjgmOTcjWYmiXF9hC2twjwt3rY7bg/ig2hcrsPhRrGCrH7jtwVlVHqxYI69iVbNLQTfhVtLQZdBlaUNkntlxMw4nwYC
# DATA Iq0enjsI++n0pZjpjmGIsFCzRITD+ZkwXugb4AKBeCcYF8+4ZNvRox6qF86+6S3rI0zs6SWJEzfffLtD8ZR/nlS5dOv2nxFRwop5
# DATA MBx0aNiroE3NqTn+HzrUkH1pkhhtxQrJR7pfzfxkv3ShsyGVyEksfE3efwrkbatxvyHCNmk6YZu5CjpOl6mty8GydTkA0927mw83
# DATA 1tzLwStVi1od+g558CgFEGwn07eU9D3L4pzKUiPpMV1Al+SuozEX3WFLyIMAD2fdMc3fgSf4C5BaRTrm0DIlveahlEIENF5RUH1I
# DATA wsZzPxag87LP2un+jl8L08OWGVNwZ3P1+3WTys36LI9R9LgxlU8TqYAiF52SVMMQ5joWqnqrlUDXt03HBFZU4T+tgyEmC8IEqz3w
# DATA h+fkmkBHrRZIMa1WKLMej2N05BD7Dz9XVsaHJwBjuIW/qExbYCFtCRmo02oVjTchP1mrza8UtIsjOm9uoQacgYbxm7ifDUeTeeWy
# DATA KS033srMk7ZzNARk4xqBHKN4qJ0mHWQDhEmXQadiKsoSCRPLytCSZuYwZBxkZiFSnhfvpP3eb+9H/Yzf0cyW3QR4g6ZXgGrTjN8Z
# DATA vTejBONScic4mJXL4j9QWuqfIFQVD9PopMc21gUXXXIH3XzrT+Auvn1C+W7IrYT2toKthlwhQCs6qYJoqGKHwuo4oLk08wa+ReYN
# DATA /CgmjD/h6vBnXAn+jLMu0dH97RIFmTiTALzvNsXBT/iZZ5q/8axmN5KgTgvSzYZwdZvO1QDvCF0tYmvquooVdFiV05ZdmbnHMmrU
# DATA +BP4EL/2unptfKj0pJd2qyrOfev13+u/13+v/17/vf57/ff67/Xf67/Xf6//Xv+9/nv99/rvMn//CQEpbmEAKA8A
# END_REMNACUST_HELPERS_V1
REMNACUST_INSTALLER_PAYLOAD_V1
if [[ $EUID == 0 ]]; then
    bash "$directory/installer.sh" "$@"
else
    sudo bash "$directory/installer.sh" "$@"
fi
