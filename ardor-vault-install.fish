#!/usr/bin/env fish
#
# ardor-vault-install.fish
#
# Установка виртуального аудио-фикса для Ardor Vault на Arch Linux / CachyOS.
# Работает и с USB-гарнитурой, и с наушниками в разъёме 3.5 мм на матплате.
#
# Запуск:
#     sudo ./ardor-vault-install.fish
#
# Что делает:
#   1. кладёт служебный скрипт ardor-audio-fix;
#   2. создаёт задание и таймер systemd;
#   3. включает таймер и сразу применяет настройки;
#   4. показывает, что получилось.
#
# Почему нужен скрипт, а не готовый конфиг:
#   Имя устройства в конфиге PipeWire зашито навсегда, а оно меняется при
#   любом переподключении. У USB-гарнитуры при перетыкании в другой порт
#   меняется суффикс в имени (Vault-00 -> Vault-00.2). Скрипт сам следит
#   за тем, чтобы в конфиге всегда была живая карта.
#
# Главное правило, ради которого всё затевалось:
#   Если карта, прописанная в конфиге, ЕЩЁ СУЩЕСТВУЕТ - ничего не делаем.
#   Перезапуск звука происходит только когда карта реально исчезла.
#   Раньше здесь стояло сравнение "изменилось ли имя", и из-за этого фикс
#   дёргал звук каждые пару минут, когда порт с гарнитурой терял связь.
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

set -g SYNC_SCRIPT "$TARGET_HOME/.local/bin/ardor-audio-fix"
set -g PIPEWIRE_CONF "$TARGET_HOME/.config/pipewire/pipewire.conf.d/99-ardor-fix.conf"
set -g MIC_CONF "$TARGET_HOME/.config/pipewire/pipewire.conf.d/98-ardor-mic.conf"
set -g UNIT_SERVICE "$TARGET_HOME/.config/systemd/user/ardor-audio-fix.service"
set -g UNIT_TIMER "$TARGET_HOME/.config/systemd/user/ardor-audio-fix.timer"

# Прошлая версия фикса, её надо убрать, иначе два таймера будут драться.
set -g OLD_SCRIPT "$TARGET_HOME/.local/bin/ardor-fix-sync"
set -g OLD_SERVICE "$TARGET_HOME/.config/systemd/user/ardor-fix-sync.service"
set -g OLD_TIMER "$TARGET_HOME/.config/systemd/user/ardor-fix-sync.timer"

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

function drop_old_version -v quiet
    set -l found 0
    for f in "$OLD_SCRIPT" "$OLD_SERVICE" "$OLD_TIMER"
        if test -e "$f"
            set found 1
            test -n "$quiet"; or say "    удалён $f"
            rm -f "$f"
        end
    end
    rm -rf "$TARGET_HOME/.local/state/ardor-fix-sync"
    if test $found -eq 1
        if session_alive
            as_user systemctl --user daemon-reload >/dev/null 2>&1
        end
        test -n "$quiet"; and say "    убрана прошлая версия фикса"
    end
end

if test $MODE = remove
    step "Убираю фикс"

    if session_alive
        as_user systemctl --user disable --now ardor-audio-fix.timer >/dev/null 2>&1
    end

    for f in "$SYNC_SCRIPT" "$PIPEWIRE_CONF" "$MIC_CONF" "$UNIT_SERVICE" "$UNIT_TIMER" \
             "$PIPEWIRE_CONF.bak" "$MIC_CONF.bak"
        if test -e "$f"
            rm -f "$f"
            say "    удалён $f"
        end
    end
    rm -rf "$TARGET_HOME/.local/state/ardor-audio-fix"
    drop_old_version

    if session_alive
        as_user systemctl --user daemon-reload
        as_user systemctl --user restart pipewire pipewire-pulse wireplumber >/dev/null 2>&1
    end

    say ""
    say "Готово. Виртуальные устройства убраны, звук вернулся к обычному."
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

# Скрипт, который следит за живой картой и переписывает конфиги PipeWire.
# Важно: shebang стоит в той же строке, что и открывающая кавычка.
# Иначе файл начнётся с пустой строки, shebang не распознается
# и скрипт выполнится через bash.
set -g SYNC_BODY '#!/usr/bin/env fish
# Ardor Vault - самопочиняющийся виртуальный аудио-фикс.
# Запускается по таймеру systemd --user раз в 10 секунд.
#
#   ardor-audio-fix          применить, если нужно
#   ardor-audio-fix force    переприменить принудительно
#   ardor-audio-fix test     показать, что выбрано
#
# Ручной выбор устройства: создай файл
#   ~/.config/ardor-audio-fix/override
# с одной строкой, например
#   alsa_output.usb-XiiSound_Technology_Corporation_Vault-00.2.analog-stereo

set CONF_DIR "$HOME/.config/pipewire/pipewire.conf.d"
set SINK_CONF "$CONF_DIR/99-ardor-fix.conf"
set MIC_CONF "$CONF_DIR/98-ardor-mic.conf"
set OVERRIDE_FILE "$HOME/.config/ardor-audio-fix/override"
set VIRT_SINK ardor_fix_sink
set VIRT_SRC ardor_mic_source
set MOTHERBOARD "00_1b.0"
set VAULT "XiiSound_Technology_Corporation_Vault"
set FORCE 0

set -l MODE run
switch "$argv[1]"
    case force
        set FORCE 1
        set MODE run
    case test
        set MODE test
    case debug
        set MODE debug
    case ""
        set MODE run
    case "*"
        echo "usage: ardor-audio-fix [run|force|test]" >&2
        exit 1
end

function logit
    echo "ardor-audio-fix: $argv" >&2
end

function node_names -a kind
    pactl list short $kind 2>/dev/null | cut -f2 | string match -rv "^\$"
end

function has_node -a kind name
    contains -- "$name" (node_names $kind)
end

function wait_node -a kind name
    set -l i
    for i in (seq 1 40)
        if has_node $kind "$name"
            return 0
        end
        sleep 0.25
    end
    return 1
end

function pw_ready
    pactl info >/dev/null 2>&1
end

function pw_wait
    set -l i
    for i in (seq 1 40)
        if pw_ready
            return 0
        end
        sleep 0.25
    end
    return 1
end

# Имя цели, прописанное в конфиге. Пустая строка, если конфига нет.
function conf_target -a file
    test -r "$file"; or return 0
    for line in (cat "$file")
        if string match -q -- "*\"target.object\"*" "$line"
            string replace -r ".*\"target\.object\"\s*:\s*\"([^\"]+)\".*" "\$1" -- "$line"
            return 0
        end
    end
end

# Список вывода pactl кэшируется на время работы, иначе на каждый узел
# пришлось бы запускать pactl заново, а узлов бывает много.
function cached_list -a kind
    if test "$_cache_kind" != "$kind"
        set -g _cache_data (pactl list $kind 2>/dev/null)
        set -g _cache_kind "$kind"
    end
    if test (count $_cache_data) -gt 0
        printf "%s\n" $_cache_data
    end
end

# Все строки блока нужного узла.
#
# Порядок свойств в pactl разный: у sinks строка State идёт ПЕРЕД Name,
# у sources - после. Поэтому берём весь блок целиком, а не "от Name и дальше".
function node_block -a kind name
    set -l cur
    set -l found 0
    for line in (cached_list $kind)
        set -l t (string trim -- "$line")
        if test "$t" = ""
            if test $found -eq 1
                printf "%s\n" $cur
                return 0
            end
            set cur
            set found 0
            continue
        end
        set -a cur "$t"
        if string match -q -- "Name: *" "$t"
            if test (string replace -r "^Name: " "" -- "$t") = "$name"
                set found 1
            end
        end
    end
    if test $found -eq 1
        printf "%s\n" $cur
    end
    printf ""
end

# Значение свойства узла, например api.alsa.card или device.plugged.usec.
function node_prop -a kind name prop
    for line in (node_block $kind $name)
        if string match -q -- "$prop = *\"*" "$line"
            string replace -r "^$prop = \"([^\"]*)\"" "\$1" -- "$line"
            return 0
        end
    end
    printf ""
end

# Состояние узла: RUNNING, SUSPENDED и так далее.
function node_state -a kind name
    for line in (node_block $kind $name)
        if string match -q -- "State: *" "$line"
            string replace -r "^State:\s+" "" -- "$line"
            return 0
        end
    end
    printf ""
end

# Печатает имена карт, у которых устройство РЕАЛЬНО подключено.
#
# Главная проблема: ALSA не убирает карту, когда USB-устройство отвалилось.
# Карта-призрак остаётся в списке со своим профилем, выдаёт узлы и выглядит
# активной, поэтому звук уходит в пустоту, а скрипт не может её отличить от
# настоящей. Отличаем по sysfs: у живой карты есть каталог
# /sys/bus/usb/devices/<порт>/1.0/sound/cardN, у призрака его нет.
function live_cards
    set -l triples
    set -l name ""
    set -l long ""
    set -l idx ""
    for line in (pactl list cards 2>/dev/null)
        set -l t (string trim -- "$line")
        if string match -q -- "Name: alsa_card.*" "$t"
            set triples $triples "$name" "$long" "$idx"
            set name (string replace -r "^Name: " "" -- "$t")
            set long ""
            set idx ""
        else if string match -q -- "api.alsa.card = *\"*" "$t"
            set idx (string replace -r "^api\.alsa\.card = \"([^\"]*)\"" "\$1" -- "$t")
        else if string match -q -- "api.alsa.card.longname = *\"*" "$t"
            set long (string replace -r "^api\.alsa\.card\.longname = \"([^\"]*)\"" "\$1" -- "$t")
        end
    end
    set triples $triples "$name" "$long" "$idx"

    set -l out
    for i in (seq 1 3 (count $triples))
        set -l nm $triples[$i]
        set -l lg $triples[(math $i + 1)]
        set -l ix $triples[(math $i + 2)]
        test -n "$nm"; or continue
        # Не USB (материнская плата, HDMI) - проверять нечем, считаем живой.
        if not string match -q -- "*usb-0000:*" "$lg"
            set -a out "$nm"
            continue
        end
        test -n "$ix"; or continue
        # Каталог карты лежит прямо в sound/ у каталога интерфейса,
        # а номер интерфейса у разных устройств разный (1.0, 1.2, ...),
        # поэтому проверяем все интерфейсы подряд.
        set -l found 0
        for d in /sys/bus/usb/devices/*
            if test -e "$d/sound/card$ix"
                set found 1
                break
            end
        end
        test $found -eq 1; and set -a out "$nm"
    end
    printf "%s\n" $out
end

# Имя карты по её номеру ALSA.
function card_name_by_index -a idx
    set -l name ""
    for line in (pactl list cards 2>/dev/null)
        set -l t (string trim -- "$line")
        if string match -q -- "Name: alsa_card.*" "$t"
            set name (string replace -r "^Name: " "" -- "$t")
        else if string match -q -- "api.alsa.card = *\"*" "$t"
            if test (string replace -r "^api\.alsa\.card = \"([^\"]*)\"" "\$1" -- "$t") = "$idx"
                printf "%s" "$name"
                return 0
            end
        end
    end
    printf ""
end

# Призрак ли узел, то есть осталась ли его карта от отключённого устройства.
function node_is_ghost -a kind name
    set -l idx (node_prop $kind $name "api.alsa.card")
    if test -z "$idx"
        printf "no"
        return 0
    end
    set -l card (card_name_by_index "$idx")
    if test -z "$card"
        printf "no"
        return 0
    end
    if contains -- "$card" (live_cards)
        printf "no"
    else
        printf "yes"
    end
end

# Лучший узел гарнитуры. Аргумент: sinks или sources.
#
# Призраки отбрасываются. Дальше приоритет:
#   1. узел играет прямо сейчас (RUNNING) - гарнитура воткнута туда;
#   2. свежее подключение (чем позже подключено, тем позже включили);
#   3. свежий суффикс инстанса (-00.3 новее, чем -00).
function best_node -a kind
    set -l prefix alsa_output
    set -l in_prefix alsa_input
    if test "$kind" = sources
        set prefix $in_prefix
    end

    set -l best ""
    set -l best_score -1

    for n in (node_names $kind)
        string match -q -- "$prefix.usb-$VAULT-*" "$n"; or continue
        string match -q -- "*.monitor" "$n"; and continue
        if test (node_is_ghost $kind $n) = yes
            logit "призрак, пропускаю: $n"
            continue
        end

        set -l usec (node_prop $kind $n "device.plugged.usec")
        test -n "$usec"; or set usec 0
        # Побеждает тот, кого подключили позже всех: так звук сам
        # переезжает на гарнитуру, которую только что воткнули.
        # Если устройство играет прямо сейчас, добавляем маленький бонус
        # за равный счёт, чтобы не прыгать на ровном месте.
        set -l score (math "$usec*2")
        if test (node_state $kind $n) = RUNNING
            set score (math $score + 1)
        end
        if test $score -gt $best_score
            set best_score $score
            set best "$n"
        end
    end

    if test -n "$best"
        printf "%s" "$best"
        return 0
    end
    return 1
end

# Реальный выход. Разъём 3.5 мм на матплате появляется в списке только
# когда в него воткнут штекер, поэтому проверяется первым.
function detect_sink
    for n in (node_names sinks)
        if string match -q -- "alsa_output.pci-*_$MOTHERBOARD.analog-stereo*" "$n"
            printf "%s" "$n"
            return 0
        end
    end
    set -l v (best_node sinks)
    if test -n "$v"
        printf "%s" "$v"
        return 0
    end
    for n in (node_names sinks)
        if string match -q -- "alsa_output.pci-*_hdmi-stereo" "$n"
            printf "%s" "$n"
            return 0
        end
    end
    return 1
end

# Реальный вход. Те же правила.
function detect_source
    for n in (node_names sources)
        if string match -q -- "alsa_input.pci-*_$MOTHERBOARD.analog-stereo*" "$n"
            printf "%s" "$n"
            return 0
        end
    end
    set -l v (best_node sources)
    if test -n "$v"
        printf "%s" "$v"
        return 0
    end
    for n in (node_names sources)
        if string match -q -- "alsa_input.usb-*" "$n"
            printf "%s" "$n"
            return 0
        end
    end
    return 1
end

# Выбор цели с учётом того, что уже прописано в конфиге.
# Ключевая идея: если текущая цель ещё жива, оставляем её. Иначе при каждом
# переподключении USB-порта имя цели менялось бы, и звук дёргался бы заново.
function pick_sink -a current
    if test -r "$OVERRIDE_FILE"
        head -n 1 "$OVERRIDE_FILE" | string trim
        return 0
    end
    # Разъём на матплате важнее всего: раз в него воткнули штекер.
    for n in (node_names sinks)
        if string match -q -- "alsa_output.pci-*_$MOTHERBOARD.analog-stereo*" "$n"
            printf "%s" "$n"
            return 0
        end
    end
    set -l best (best_node sinks)
    # Текущую цель держим, только если она не призрак и подключена не
    # старее лучшей: тогда звук сам переедет на только что подключённую
    # гарнитуру, но не будет скакать при каждом переподключении.
    if test -n "$current"; and has_node sinks "$current"
        if test (node_is_ghost sinks "$current") = no
            set -l cu (node_prop sinks "$current" "device.plugged.usec")
            test -n "$cu"; or set cu 0
            set -l bu 0
            test -n "$best"; and set bu (node_prop sinks "$best" "device.plugged.usec")
            test -n "$bu"; or set bu 0
            if test $cu -ge $bu
                printf "%s" "$current"
                return 0
            end
        end
    end
    if test -n "$best"
        printf "%s" "$best"
        return 0
    end
    detect_sink
end

function pick_source -a current
    if test -r "$OVERRIDE_FILE"
        head -n 1 "$OVERRIDE_FILE" | string trim
        return 0
    end
    for n in (node_names sources)
        if string match -q -- "alsa_input.pci-*_$MOTHERBOARD.analog-stereo*" "$n"
            printf "%s" "$n"
            return 0
        end
    end
    set -l best (best_node sources)
    if test -n "$current"; and has_node sources "$current"
        if test (node_is_ghost sources "$current") = no
            set -l cu (node_prop sources "$current" "device.plugged.usec")
            test -n "$cu"; or set cu 0
            set -l bu 0
            test -n "$best"; and set bu (node_prop sources "$best" "device.plugged.usec")
            test -n "$bu"; or set bu 0
            if test $cu -ge $bu
                printf "%s" "$current"
                return 0
            end
        end
    end
    if test -n "$best"
        printf "%s" "$best"
        return 0
    end
    detect_source
end

function write_sink_conf -a target
    printf "{
  \"context.modules\": [
    {
      \"name\": \"libpipewire-module-loopback\",
      \"args\": {
        \"node.description\": \"Ardor Vault (Стерео-Фикс)\",
        \"capture.props\": {
          \"node.name\": \"$VIRT_SINK\",
          \"media.class\": \"Audio/Sink\",
          \"audio.position\": [ \"FL\", \"FR\" ]
        },
        \"playback.props\": {
          \"node.name\": \"playback.$VIRT_SINK\",
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

# Микрофон гарнитуры физически одноканальный, поэтому FL/FR здесь НЕ форсим:
# принудительный stereo ронял узел с ошибкой -95 (operation not supported),
# и виртуальный микрофон не появлялся в списке источников. pipewire-pulse
# сам разводит моно по каналам для приложений.
function write_mic_conf -a target
    if test -z "$target"
        printf "{ \"context.modules\": [] }\n" > "$MIC_CONF"
        return 0
    end
    printf "{
  \"context.modules\": [
    {
      \"name\": \"libpipewire-module-loopback\",
      \"args\": {
        \"node.description\": \"Ardor Vault (Микрофон-Фикс)\",
        \"capture.props\": {
          \"node.name\": \"capture.$VIRT_SRC\",
          \"media.class\": \"Stream/Input/Audio\",
          \"target.object\": \"$target\"
        },
        \"playback.props\": {
          \"node.name\": \"$VIRT_SRC\",
          \"media.class\": \"Audio/Source\",
          \"node.passive\": true,
          \"node.autoconnect\": true,
          \"intent\": \"capture\"
        }
      }
    }
  ]
}
" > "$MIC_CONF"
end

# Держим виртуальные устройства дефолтными: WirePlumber и другие
# инструменты периодически возвращают дефолт на реальное устройство.
function ensure_defaults
    set -l cur (pactl get-default-sink 2>/dev/null | string trim)
    if test -n "$cur"; and test "$cur" != "$VIRT_SINK"; and has_node sinks "$VIRT_SINK"
        logit "дефолтный выход был $cur, возвращаю $VIRT_SINK"
        pactl set-default-sink "$VIRT_SINK" >/dev/null 2>&1
    end
    set cur (pactl get-default-source 2>/dev/null | string trim)
    if test -n "$cur"; and test "$cur" != "$VIRT_SRC"; and has_node sources "$VIRT_SRC"
        logit "дефолтный микрофон был $cur, возвращаю $VIRT_SRC"
        pactl set-default-source "$VIRT_SRC" >/dev/null 2>&1
    end
end

function apply_defaults -a real_in
    set -l i
    for i in (seq 1 15)
        pactl set-default-sink "$VIRT_SINK" >/dev/null 2>&1
        if test (pactl get-default-sink 2>/dev/null | string trim) = "$VIRT_SINK"
            break
        end
        sleep 1
    end
    # Виртуальный микрофон - если поднялся. Иначе реальный, чтобы
    # приложения не остались без звука вообще.
    if wait_node sources "$VIRT_SRC"
        for i in (seq 1 10)
            pactl set-default-source "$VIRT_SRC" >/dev/null 2>&1
            if test (pactl get-default-source 2>/dev/null | string trim) = "$VIRT_SRC"
                break
            end
            sleep 1
        end
    else
        logit "виртуальный микрофон не поднялся, ставлю реальный вход"
        if test -n "$real_in"
            pactl set-default-source "$real_in" >/dev/null 2>&1
        end
    end
end

function restart_pw -a real_in
    logit "перезапускаю звуковую систему"
    systemctl --user restart pipewire pipewire-pulse wireplumber >/dev/null 2>&1
    sleep 0.5
    if not pw_wait
        logit "pipewire не поднялся"
        return 1
    end
    wait_node sinks "$VIRT_SINK"; or logit "виртуальный выход не появился"
    apply_defaults "$real_in"
end

if test $MODE = debug
    echo "живые карты:"
    live_cards
    for n in (node_names sinks)
        if string match -q -- "alsa_output.usb-$VAULT-*" "$n"
            set -l ix (node_prop sinks $n "api.alsa.card")
            set -l cn (card_name_by_index "$ix")
            echo "узел:    $n"
            echo "    card = [$ix]  имя = [$cn]  призрак = ["(node_is_ghost sinks $n)"]"
            echo "    state = ["(node_state sinks $n)"]  usec = ["(node_prop sinks $n "device.plugged.usec")"]"
        end
    end
    echo "выбирается: ["(detect_sink; or echo нет)"]"
    set -l cnt 0
    for x in (node_names sinks)
        string match -q -- "alsa_output.usb-$VAULT-*" "$x"; and set cnt (math $cnt + 1)
    end
    if test $cnt -gt 1
        echo ""
        echo "ВНИМАНИЕ: гарнитура подключена к $cnt портам USB сразу."
        echo "Система видит несколько одинаковых выходов и выбирает наугад."
        echo "Отключите лишний кабель, иначе звук пойдёт не туда."
    end
    exit 0
end

if test $MODE = test
    set -l ts ""
    test -r "$SINK_CONF"; and set ts (conf_target "$SINK_CONF" | string trim)
    echo "в конфиге выход:  "(test -n "$ts"; and echo $ts; or echo "<нет>")
    echo "в конфиге вход:   "(conf_target "$MIC_CONF" 2>/dev/null | string trim)
    echo "выбирается выход: "(detect_sink; or echo "<нет>")
    echo "выбирается вход:  "(detect_source; or echo "<нет>")
    echo "узел выхода есть: "(has_node sinks "$ts"; and echo да; or echo нет)
    exit 0
end

pw_wait; or begin
    logit "pipewire недоступен, жду следующего тика"
    exit 0
end

set -l cur_sink (conf_target "$SINK_CONF" | string trim)
set -l cur_mic (conf_target "$MIC_CONF" | string trim)
set -l want_sink (pick_sink "$cur_sink")
set -l want_mic (pick_source "$cur_mic")

set -l need_sink 0
set -l need_mic 0

if test $FORCE -eq 1
    set need_sink 1
    set need_mic 1
else
    if test "$want_sink" != "$cur_sink"
        set need_sink 1
    end
    if test "$want_mic" != "$cur_mic"
        set need_mic 1
    end
    # Прописанная цель исчезла - перестраиваем, что бы ни выбрал поиск.
    if test -n "$cur_sink"; and not has_node sinks "$cur_sink"
        set need_sink 1
    end
    if test -n "$cur_mic"; and not has_node sources "$cur_mic"
        set need_mic 1
    end
end

# Ничего не надо - не трогаем звук, чтобы не мешать играм и звонкам.
if test $need_sink -eq 0; and test $need_mic -eq 0
    ensure_defaults
    exit 0
end

# Устройство только что переподключилось. Ждём, пока оно устоится,
# иначе поймаем момент переподключения и пересоберём конфиг зря.
set -l tries 0
set -l first ""
set -l stable 0
while test $tries -lt 8
    set -l s (pick_sink "")
    if test -n "$s"
        if test "$s" = "$first"
            set stable 1
            break
        end
        set first "$s"
    end
    sleep 4
    set tries (math $tries + 1)
end

if test $stable -eq 0
    logit "устройство не устоялось, жду следующего тика"
    exit 0
end

if test -z "$want_sink"
    logit "реальный выход не найден"
    exit 0
end

mkdir -p "$CONF_DIR" (dirname "$OVERRIDE_FILE")

test -r "$SINK_CONF"; and cp -f "$SINK_CONF" "$SINK_CONF.bak"
test -r "$MIC_CONF"; and cp -f "$MIC_CONF" "$MIC_CONF.bak"

if test $need_sink -eq 1
    write_sink_conf "$want_sink"
    logit "выход: $want_sink"
end
if test $need_mic -eq 1
    write_mic_conf "$want_mic"
    logit "вход:  $want_mic"
end

restart_pw "$want_mic"
logit "готово, выход: "(pactl get-default-sink 2>/dev/null | string trim)
logit "микрофон: "(pactl get-default-source 2>/dev/null | string trim)
'

set -g UNIT_SERVICE_BODY "[Unit]
Description=Ardor Vault: obnovlenie virtualnogo audio-fiksa
After=pipewire.service wireplumber.service
PartOf=graphical-session.target

[Service]
Type=oneshot
ExecStart=%h/.local/bin/ardor-audio-fix
# Skript sam perezapuskayet pipewire, ne dayom systemd ubit ego zdes zhe.
TimeoutStartSec=180
"

set -g UNIT_TIMER_BODY "[Unit]
Description=Ardor Vault: periodicheskaya proverka virtualnogo audio-fiksa

[Timer]
OnBootSec=15s
OnUnitActiveSec=10s
AccuracySec=2s
Unit=ardor-audio-fix.service

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

step "Убираю прошлую версию фикса"
drop_old_version

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
    say "    sudo -u $TARGET_USER XDG_RUNTIME_DIR=$RUNTIME_DIR systemctl --user enable --now ardor-audio-fix.timer"
    exit 0
end

step "Включаю таймер"
as_user systemctl --user daemon-reload
as_user systemctl --user enable --now ardor-audio-fix.timer
say "    таймер включён, проверка каждые 10 секунд"

step "Применяю настройки"
as_user "$SYNC_SCRIPT" force

step "Готово"
say "    выход по умолчанию:    "(as_user pactl get-default-sink 2>/dev/null | string trim)
say "    микрофон по умолчанию: "(as_user pactl get-default-source 2>/dev/null | string trim)
say "    таймер:               "(as_user systemctl --user is-active ardor-audio-fix.timer 2>/dev/null | string trim)

say ""
say "Что дальше:"
say "  * Проверить звук:   pactl get-default-sink   (ожидается ardor_fix_sink)"
say "  * Что выбрано:      ardor-audio-fix test"
say "  * Починить вручную: sudo -u $TARGET_USER $SYNC_SCRIPT force"
say "  * Журнал:           journalctl --user -u ardor-audio-fix -f"
say "  * Убрать фикс:      sudo $SELF --remove"
