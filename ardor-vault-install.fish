#!/usr/bin/env fish
#
# ardor-vault-install.fish
#
# Установка фикса звука для USB-ЦАП Ardor Vault на Arch Linux / CachyOS.
#
# Запуск:
#     sudo ./ardor-vault-install.fish
#
# Что делает:
#   1. кладёт служебный скрипт, который следит за рабочей картой Vault;
#   2. создаёт задание и таймер systemd для автозапуска;
#   3. включает таймер и сразу применяет настройки;
#   4. показывает, что получилось.
#
# Почему нужен скрипт, а не готовый конфиг:
#   У Vault два USB-выхода, поэтому Linux видит две карты с одинаковым
#   именем. Живая карта при переподключении меняет суффикс в имени
#   (например, с -00 на -00.2). Имя устройства в конфиге PipeWire зашито
#   навсегда, поэтому после переподключения звук уходит в пустую карту.
#   Скрипт находит рабочую карту сам и правит конфиг, но только если имя
#   реально изменилось, чтобы зря не прерывать игры и звонки.
#
# Ключи:
#   --user ИМЯ   установить фикс для другого пользователя
#   --remove     убрать фикс и вернуть звук как было
#   --help       эта справка

set -g SELF (status filename)
set -g TARGET_USER ""
set -g MODE install

# ---------------------------------------------------------------- разбор ключей

set -l i 1
while test $i -le (count $argv)
    switch $argv[$i]
        case --user -u
            set j (math $i + 1)
            if test $j -gt (count $argv)
                echo "Ошибка: после --user нужно имя пользователя." >&2
                exit 2
            end
            set TARGET_USER $argv[$j]
            set i (math $i + 1)
        case --remove
            set MODE remove
        case --help -h
            sed -n "2,/^set -g TARGET_USER/p" "$SELF" | sed -e "s/^# \{0,1\}//" -e "/^set -g/d"
            exit 0
        case "*"
            echo "Ошибка: неизвестный ключ $argv[$i]" >&2
            echo "Справка: $SELF --help" >&2
            exit 2
    end
    set i (math $i + 1)
end

# ------------------------------------------------------------------ сообщения

function say
    echo "$argv[1]"
end

function step
    echo ""
    echo "==> $argv[1]"
end

function warn
    echo "Внимание: $argv[1]" >&2
end

function die
    echo "Ошибка: $argv[1]" >&2
    exit 1
end

# ------------------------------------------------------ определение пользователя

if test -z "$TARGET_USER"
    if test "$EUID" -eq 0
        if set -q SUDO_USER; and test -n "$SUDO_USER"
            set TARGET_USER $SUDO_USER
        else
            set -l homes (ls /home 2>/dev/null)
            if test (count $homes) -gt 0
                set TARGET_USER (getent passwd $homes[1] | cut -d: -f1)
            end
        end
    else
        set TARGET_USER (id -un)
    end
end

if test -z "$TARGET_USER"
    die "не удалось определить пользователя. Запустите с --user ИМЯ"
end

id $TARGET_USER >/dev/null 2>&1; or die "пользователь $TARGET_USER не найден"

set -g TARGET_UID (id -u $TARGET_USER)
set -g TARGET_GROUP (id -gn $TARGET_USER)
set -g TARGET_HOME (eval echo "~$TARGET_USER")
set -g RUNTIME_DIR /run/user/$TARGET_UID

test -d "$TARGET_HOME"; or die "домашний каталог $TARGET_HOME не найден"

set -g SYNC_SCRIPT "$TARGET_HOME/.local/bin/ardor-fix-sync"
set -g PIPEWIRE_CONF "$TARGET_HOME/.config/pipewire/pipewire.conf.d/99-ardor-fix.conf"
set -g UNIT_SERVICE "$TARGET_HOME/.config/systemd/user/ardor-fix-sync.service"
set -g UNIT_TIMER "$TARGET_HOME/.config/systemd/user/ardor-fix-sync.timer"

# Команда от имени пользователя внутри его графической сессии.
# Через sudo с подменой переменных окружения, иначе systemctl --user
# не найдёт нужную сессию и будет ругаться на отсутствие шины.
function as_user
    if test "$EUID" -eq 0
        sudo -u $TARGET_USER -H env XDG_RUNTIME_DIR=$RUNTIME_DIR \
            DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus $argv
    else
        env XDG_RUNTIME_DIR=$RUNTIME_DIR \
            DBUS_SESSION_BUS_ADDRESS=unix:path=$RUNTIME_DIR/bus $argv
    end
end

function session_alive
    test -d $RUNTIME_DIR; or return 1
    as_user systemctl --user show-environment >/dev/null 2>&1
end

# ------------------------------------------------------------ проверка системы

step "Проверяю систему"

for tool in pipewire wireplumber pactl systemctl
    command -q $tool; or die "$tool не найден. Нужны pipewire, wireplumber и pulse-utils"
end

set -g PRETTY_NAME (grep ^PRETTY_NAME= /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d "\"")
say "    система: $PRETTY_NAME"
say "    пользователь: $TARGET_USER"
say "    домашний каталог: $TARGET_HOME"

if test "$EUID" -ne 0
    warn "скрипт запущен не от root, файлы будут созданы от вашего имени"
end

# --------------------------------------------------------------------- удаление

if test $MODE = remove
    step "Убираю фикс"

    if session_alive
        as_user systemctl --user disable --now ardor-fix-sync.timer >/dev/null 2>&1
    end

    for f in "$SYNC_SCRIPT" "$PIPEWIRE_CONF" "$UNIT_SERVICE" "$UNIT_TIMER" "$PIPEWIRE_CONF.bak"
        if test -e "$f"
            rm -f "$f"
            say "    удалён $f"
        end
    end
    rm -rf "$TARGET_HOME/.local/state/ardor-fix-sync"

    if session_alive
        as_user systemctl --user daemon-reload
        as_user systemctl --user restart pipewire pipewire-pulse wireplumber >/dev/null 2>&1
    end

    say ""
    say "Готово. Виртуальное устройство убрано, звук вернулся к обычному."
    exit 0
end

# ------------------------------------------------------------ проверка сессии

step "Проверяю графическую сессию"

if session_alive
    say "    сессия доступна, настройки применятся сразу"
else
    warn "сессия пользователя сейчас не запущена"
    say "    Это нормально, если скрипт запускают до входа в рабочий стол."
    say "    Таймер включится, а звук починится сам при первом входе."
end

# ------------------------------------------------------------------- содержимое

# Скрипт, который ищет рабочую карту и обновляет конфиг PipeWire.
# Важно: shebang стоит в той же строке, что и открывающая кавычка.
# Иначе файл начнётся с пустой строки, shebang не распознается
# и скрипт выполнится через bash.
set -g SYNC_BODY '#!/usr/bin/env fish
# Следит за рабочей картой Ardor Vault и обновляет конфиг PipeWire.
# Запускается по таймеру systemd --user. Можно запускать и вручную.

set CONF_DIR "$HOME/.config/pipewire/pipewire.conf.d"
set SINK_CONF "$CONF_DIR/99-ardor-fix.conf"
set STATE_FILE "$HOME/.local/state/ardor-fix-sync/last-target"
set VIRTUAL_SINK ardor_fix_sink
set VAULT_RE "alsa_(output|input)\.usb-XiiSound_Technology_Corporation_Vault"

function logit
    echo "ardor-fix: $argv" >&2
end

# Печатает имя рабочего узла Vault. Аргумент: sinks или sources.
# Приоритет: узел в состоянии RUNNING, затем текущий default,
# затем карта с наибольшим номером, то есть подключённая последней.
function pick_live -a kind
    set default_node (pactl get-default-$kind 2>/dev/null | head -n 1 | string trim)
    set best ""
    set best_score -1

    for line in (pactl list short $kind 2>/dev/null)
        set -l fields (string split \t -- "$line")
        set -l name $fields[2]
        if test -z "$name"
            continue
        end
        if not string match -rq -- "$VAULT_RE" "$name"
            continue
        end
        if string match -q -- "*.monitor" "$name"
            continue
        end
        if test "$name" = "$VIRTUAL_SINK"
            continue
        end

        set -l state $fields[-1]
        set -l score 0
        if test "$state" = "RUNNING"
            set score (math $score + 100)
        end
        if test "$name" = "$default_node"
            set score (math $score + 20)
        end

        # Номер экземпляра карты. Имя ..._Vault-00.2.analog-stereo даёт 2,
        # а ..._Vault-00.analog-stereo даёт 0.
        set -l inst (string replace -r "^.*_Vault-00" "" "$name")
        set -l num (string replace -r "^\.([0-9]+)\..*\$" "\$1" "$inst")
        if string match -rq "^[0-9]+\$" -- "$num"
            set score (math $score + $num)
        end

        if test $score -gt $best_score
            set best_score $score
            set best "$name"
        end
    end

    printf "%s" "$best"
end

function render_sink_conf -a target
    printf "{
  \"context.modules\": [
    {
      \"name\": \"libpipewire-module-loopback\",
      \"args\": {
        \"node.description\": \"Ardor Vault (Стерео-Фикс)\",
        \"capture.props\": {
          \"node.name\": \"$VIRTUAL_SINK\",
          \"media.class\": \"Audio/Sink\",
          \"audio.position\": [ \"FL\", \"FR\" ]
        },
        \"playback.props\": {
          \"node.name\": \"playback.$VIRTUAL_SINK\",
          \"audio.position\": [ \"FL\", \"FR\" ],
          \"target.object\": \"$target\",
          \"stream.dont-remix\": true,
          \"node.passive\": true,
          \"node.autoconnect\": true,
          \"intent\": \"playback\"
        }
      }
    }
  ]
}
" > "$SINK_CONF"
end

set -l tries 0
while not pactl info >/dev/null 2>&1
    set tries (math $tries + 1)
    if test $tries -gt 30
        exit 0
    end
    sleep 1
end

set -l live_out (pick_live sinks)
set -l live_in (pick_live sources)
set -l cur "$live_out|$live_in"

set -l prev ""
if test -r "$STATE_FILE"
    set prev (cat "$STATE_FILE" | string trim)
end

# Ничего не изменилось: не трогаем звук, чтобы не мешать играм и звонкам.
if test "$cur" = "$prev"; and test -r "$SINK_CONF"
    exit 0
end

if test -z "$live_out"
    logit "рабочая карта Vault не найдена, наушники не подключены. Конфиг не трогаю"
    exit 0
end

logit "рабочая карта: $live_out"
logit "микрофон: $live_in"

mkdir -p "$CONF_DIR" (dirname "$STATE_FILE")
if test -r "$SINK_CONF"
    cp -f "$SINK_CONF" "$SINK_CONF.bak"
end
render_sink_conf "$live_out"
printf "%s" "$cur" > "$STATE_FILE"

logit "перезапускаю звуковую систему"
systemctl --user restart pipewire pipewire-pulse wireplumber >/dev/null 2>&1

set -l attempt
for attempt in (seq 1 30)
    if pactl info >/dev/null 2>&1
        if pactl list short sinks 2>/dev/null | string match -q -- "*$VIRTUAL_SINK*"
            break
        end
    end
    sleep 1
end

for attempt in (seq 1 15)
    pactl set-default-sink "$VIRTUAL_SINK" >/dev/null 2>&1
    if test (pactl get-default-sink 2>/dev/null | string trim) = "$VIRTUAL_SINK"
        break
    end
    sleep 1
end

if test -n "$live_in"
    for attempt in (seq 1 10)
        pactl set-default-source "$live_in" >/dev/null 2>&1
        if test (pactl get-default-source 2>/dev/null | string trim) = "$live_in"
            break
        end
        sleep 1
    end
end

logit "готово, выход: "(pactl get-default-sink 2>/dev/null | string trim)
logit "микрофон: "(pactl get-default-source 2>/dev/null | string trim)
'

set -g UNIT_SERVICE_BODY "[Unit]
Description=Ardor Vault: obnovlenie virtualnogo stereo-fiksa
After=pipewire.service wireplumber.service
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/ardor-fix-sync
# Skript sam perezapuskayet pipewire, ne dayom systemd ubit ego zdes zhe.
TimeoutStartSec=180
"

set -g UNIT_TIMER_BODY "[Unit]
Description=Ardor Vault: periodicheskaya proverka virtualnogo stereo-fiksa

[Timer]
OnBootSec=15s
OnUnitActiveSec=10s
AccuracySec=2s
Unit=ardor-fix-sync.service

[Install]
WantedBy=timers.target
"

# ------------------------------------------------------------------- установка

function put_file -a dest mode content
    set -l tmp (mktemp)
    printf "%s\n" "$content" > $tmp
    # Страховка: исполняемые файлы обязаны начинаться с shebang,
    # иначе система запустит их через bash и всё сломается.
    if test $mode = 755
        if not head -n 1 $tmp | string match -q "#!*"
            rm -f $tmp
            die "внутренняя ошибка: $dest не начинается с shebang"
        end
    end
    install -d -m 755 -o $TARGET_USER -g $TARGET_GROUP (dirname "$dest")
    install -m $mode -o $TARGET_USER -g $TARGET_GROUP $tmp "$dest"
    rm -f $tmp
end

step "Ставлю служебный скрипт"
put_file "$SYNC_SCRIPT" 755 $SYNC_BODY
say "    $SYNC_SCRIPT"

step "Создаю задание systemd"
put_file "$UNIT_SERVICE" 644 $UNIT_SERVICE_BODY
say "    $UNIT_SERVICE"

step "Создаю таймер"
put_file "$UNIT_TIMER" 644 $UNIT_TIMER_BODY
say "    $UNIT_TIMER"

if not session_alive
    say ""
    say "Файлы установлены. Включить таймер можно позже командой:"
    say "    sudo -u $TARGET_USER XDG_RUNTIME_DIR=$RUNTIME_DIR systemctl --user enable --now ardor-fix-sync.timer"
    exit 0
end

step "Включаю таймер"
as_user systemctl --user daemon-reload
as_user systemctl --user enable --now ardor-fix-sync.timer
say "    таймер включён, проверка каждые 10 секунд"

step "Применяю настройки"
as_user "$SYNC_SCRIPT"
as_user systemctl --user set-default-sink ardor_fix_sink >/dev/null 2>&1

step "Готово"
say "    выход по умолчанию:    "(as_user pactl get-default-sink 2>/dev/null | string trim)
say "    микрофон по умолчанию: "(as_user pactl get-default-source 2>/dev/null | string trim)
say "    таймер:               "(as_user systemctl --user is-active ardor-fix-sync.timer 2>/dev/null | string trim)

say ""
say "Что дальше:"
say "  * Проверить звук:   pactl get-default-sink   (ожидается ardor_fix_sink)"
say "  * Починить вручную: sudo -u $TARGET_USER $SYNC_SCRIPT"
say "  * Журнал:           journalctl --user -u ardor-fix-sync.service -f"
say "  * Убрать фикс:      sudo $SELF --remove"
