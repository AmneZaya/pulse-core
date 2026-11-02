#!/bin/bash
# ══════════════════════════════════════════════════════════════════════════════
# goAmnezia pro — lib/kmod.sh: модуль ядра AmneziaWG по выбору человека (docs/KMOD_PLAN.md, этап Б)
#
# По умолчанию профили работают программой amneziawg-go в Docker, как в приложении Amnezia (решение владельца
# 08.10.2026). Модуль ядра шифрует прямо в ядре: на 1 vCPU от клиента в 1,26–1,5 раза больше скорости и память не
# растёт (замеры 08.10, .claude/work/stands/kmod-0810). Ставится только по согласию: SSH-меню «Обслуживание →
# Ускорение AmneziaWG», мост kmod-install и kmod-engine (бот и панель — карточкой с кнопкой). Сам продукт движок не
# меняет никогда; рецепт — навык Kaskad amneziawg-kernel-module (references/implementation.md).
#
# Что здесь и почему так:
#   • проверка хоста (ga_kmod_check_json) — одной фразой с причиной: контейнер LXC/OpenVZ, Secure Boot, архитектура,
#     ядро старше 5.4, мало места, нет заголовков;
#   • пакеты — с ожиданием блокировки apt и записью «что поставил я» (назовём при удалении). Заголовки — только
#     linux-headers-$(uname -r): метапакет на сервере с linux-generic тянет новое ядро и 891 МБ (KMOD-05), он ставится
#     сам, только если apt-get -s не обновляет ядро, иначе — по отдельному согласию с размером;
#   • исходники — архив тега с проверкой sha256 (другой не собирается), патчи из lib/upstream/kmod (GPL-2.0): #218 —
#     по заголовкам ядра, а не по номеру (KMOD-04), набор kaskad-k31.1 — --dry-run, потом наложение; метка та же, что
#     у Kaskad: модуль соседа с этой меткой не пересобирается, а используется;
#   • dkms.conf без AUTOINSTALL — строка убирается целиком: dkms 3.0.11 любое непустое значение считает «да»
#     (KMOD-09); без REMAKE_INITRD. Под новые ядра собирают свои хуки zz-goamnezia-amneziawg с «|| true»: apt не валят;
#   • самопроверка до перевода — в сетевых пространствах одноразового привилегированного контейнера из образа
#     профилей: модуль↔модуль и модуль←программа на линиях установленных профилей. Живой тест #253 (syncconf с ключом
#     защиты под трафиком) не запускается никогда: он вешает сервер;
#   • перевод — по одному (awg2, awg1, awg3) с копией state/ (три последние), и до 3 минут ждём, что вернётся хоть
#     один из тех, кто был на связи до смены; не вернулся никто — откат всего сервера на прежний движок;
#   • режим «программа» при загруженном модуле (KMOD-06): модуль грузится сам по `ip link add … type amneziawg` даже
#     из контейнера (request_module), выгрузка и WG_QUICK_USERSPACE_IMPLEMENTATION программу не возвращают. Поэтому
#     желаемый движок лежит файлом /opt/amnezia/awg/engine (в копии — state/<контейнер>/engine), а start.sh при
#     program поднимает интерфейс сам: amneziawg-go, awg setconf, адрес, MTU, маршруты (блок goamnezia-engine,
#     POSIX sh — goWARP проверяет start.sh через `sh -n`; блок goWARP и правки приложения не трогаются);
#   • видимость: status.kmod (фактическое и выбранное), движок профиля в profiles-status и карточке SSH, сторож
#     говорит словами с ядром, если после перезагрузки модуля под новое ядро нет и профили ушли на программу.
#
# Стенд (GOAMNEZIA_DRY_RUN=1): хост трогается только через подменённые пути (GOAMNEZIA_KMOD_ETC, _SRC_ROOT, _LIBMOD) —
# без них установка и удаление отказывают; команды хоста (dkms, modprobe, apt-get, uname…) — заглушки в PATH проверки;
# часы — GA_KMOD_CLOCK_FILE; ответы контейнера после перезапуска — фикстуры .iplink.<движок> и .awgshow.<движок>.
# Зависимости: lib/common.sh, lib/docker.sh, lib/amnezia.sh (ga_amn_engine, ga_kmod_sys_dir, GA_KMOD_PATCH_RE).
# ══════════════════════════════════════════════════════════════════════════════

GA_KMOD_VER="3.1.20260906"
GA_KMOD_TAG="v${GA_KMOD_VER}"
GA_KMOD_SET="kaskad-k31.1"
GA_KMOD_LABEL="${GA_KMOD_VER}+${GA_KMOD_SET}"
GA_KMOD_SHA256_PIN="e32fa46f1b6f9e319c5261f0b0765c3a9261e40cb7c4616fd73500da961a2932"
GA_KMOD_PATCH_218_SHA="edcb1dfbb8bdd8e960b91f03e302fe3d4330f176e6a25c55e43d026fd5ed907d"
GA_KMOD_PATCH_31_SHA="5e7ed57d114b5462ee5bf9d38b6666a41ce4ff90a39efb3980b36fcff9b7b603"
GA_KMOD_URL_DEFAULT="https://github.com/amnezia-vpn/amneziawg-linux-kernel-module/archive/refs/tags/${GA_KMOD_TAG}.tar.gz"
GA_KMOD_MIN_DISK_MB=600
GA_KMOD_ALIVE_WINDOW=180        # «на связи до смены»: рукопожатие моложе 3 минут
GA_KMOD_WAIT_CLIENTS=180        # сколько ждать, что хоть один из них вернулся
GA_KMOD_POLL=5
GA_KMOD_ORDER="awg2 awg1 awg3"  # порядок перевода (KMOD_PLAN, Б8)
GA_KMOD_COPIES_KEEP=3
GA_KMOD_HOOK="zz-goamnezia-amneziawg"
GA_KMOD_ENGINE_PATH="/opt/amnezia/awg/engine"
GA_KMOD_BLOCK_BEGIN="# --- goamnezia-engine BEGIN ---"
GA_KMOD_BLOCK_END="# --- goamnezia-engine END ---"
# Строка подъёма интерфейса в start.sh приложения (и в нашей копии lib/upstream/awg/start.sh) — её заменяет блок.
GA_KMOD_UP_LINE='if [ -f /opt/amnezia/awg/awg0.conf ]; then (awg-quick up /opt/amnezia/awg/awg0.conf); fi'
# Заголовки ядра объявляют новую сигнатуру setup_udp_tunnel_sock(struct net *, struct sock *) — нужен #218.
GA_KMOD_218_RE='setup_udp_tunnel_sock[[:space:]]*\([[:space:]]*struct[[:space:]]+net[[:space:]]*\*[[:space:]]*[[:alnum:]_]*[[:space:]]*,[[:space:]]*struct[[:space:]]+sock[[:space:]]*\*|udp_tunnel_sock_release[[:space:]]*\([[:space:]]*struct[[:space:]]+sock[[:space:]]*\*'

# ── Пути (стенд подменяет) и мелочи ──────────────────────────────────────────
_ga_kmod_etc()      { printf '%s' "${GOAMNEZIA_KMOD_ETC:-/etc}"; }
_ga_kmod_srcroot()  { printf '%s' "${GOAMNEZIA_KMOD_SRC_ROOT:-/usr/src}"; }
_ga_kmod_libmod()   { printf '%s' "${GOAMNEZIA_KMOD_LIBMOD:-/lib/modules}"; }
_ga_kmod_dkmstree() { printf '%s' "${GOAMNEZIA_KMOD_DKMS_TREE:-/var/lib/dkms}"; }
_ga_kmod_proc()     { printf '%s' "${GOAMNEZIA_KMOD_PROC:-/proc}"; }
_ga_kmod_efivars()  { printf '%s' "${GOAMNEZIA_KMOD_EFIVARS:-/sys/firmware/efi/efivars}"; }
ga_kmod_src_dir()   { printf '%s/amneziawg-%s' "$(_ga_kmod_srcroot)" "$GA_KMOD_VER"; }
ga_kmod_state_file() { printf '%s/kmod.json' "${STATE_DIR:-${GOAMNEZIA_DIR:-/opt/goamnezia}/state}"; }
_ga_kmod_progress_file() { printf '%s/kmod-progress.json' "${LOCK_DIR:-/run/goamnezia}"; }
_ga_kmod_engines_file()  { printf '%s/kmod-engines.json' "${LOCK_DIR:-/run/goamnezia}"; }
_ga_kmod_copies_dir()    { printf '%s/.kmod-copies' "${STATE_DIR:-${GOAMNEZIA_DIR:-/opt/goamnezia}/state}"; }
_ga_kmod_hook_paths() {
    printf '%s/kernel/postinst.d/%s\n%s/kernel/header_postinst.d/%s\n' \
        "$(_ga_kmod_etc)" "$GA_KMOD_HOOK" "$(_ga_kmod_etc)" "$GA_KMOD_HOOK"
}
_ga_kmod_modload_file() { printf '%s/modules-load.d/amneziawg.conf' "$(_ga_kmod_etc)"; }

# Каталог патчей — рядом с вендоренным upstream (lib/upstream/kmod). Стенд может подложить свой — только в сухом
# прогоне: в работе патчи и их sha256 закреплены кодом.
_ga_kmod_patch_dir() {
    if ga_dry && [ -n "${GOAMNEZIA_KMOD_PATCH_DIR:-}" ]; then printf '%s' "$GOAMNEZIA_KMOD_PATCH_DIR"; return 0; fi
    printf '%s/kmod' "${UPSTREAM_DIR:-$GA_LIB_DIR/upstream}"
}

# _ga_kmod_pin <переменная окружения> <закреплённое значение> — sha256 и прочее закреплённое: подменить можно только
# на стенде (GOAMNEZIA_DRY_RUN=1), на сервере всегда закреплённое.
_ga_kmod_pin() {
    local v=""
    if ga_dry; then v="${!1:-}"; fi
    printf '%s' "${v:-$2}"
}

# Часы: стенд двигает их сам (GA_KMOD_CLOCK_FILE — секунды эпохи в файле), чтобы «3 минуты ожидания» шли мгновенно.
_ga_kmod_now() {
    local n=""
    if ga_dry && [ -n "${GA_KMOD_CLOCK_FILE:-}" ]; then n=$(head -n 1 "$GA_KMOD_CLOCK_FILE" 2>/dev/null | tr -cd '0-9'); fi
    printf '%s' "${n:-$(date -u +%s)}"
}
_ga_kmod_sleep() {
    local s="${1:-1}" n
    if ga_dry && [ -n "${GA_KMOD_CLOCK_FILE:-}" ]; then
        n=$(_ga_kmod_now)
        printf '%s\n' "$((n + s))" >"$GA_KMOD_CLOCK_FILE"
        return 0
    fi
    sleep "$s"
}

ga_kmod_kernel() { uname -r 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9._+~-'; }
_ga_kmod_arch() { uname -m 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9_-'; }
_ga_kmod_sha256() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" 2>/dev/null | awk '{print $1}'
    else shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'; fi
}
_ga_kmod_boot_id() { head -c 64 "$(_ga_kmod_proc)/sys/kernel/random/boot_id" 2>/dev/null | tr -cd '0-9a-f-'; }

# На стенде хост трогается только через подменённые пути: без них сухой прогон писал бы в /etc и /usr/src машины,
# где идёт проверка (так же «Удалить всё» на стенде, L2-09).
_ga_kmod_host_paths_ok() {
    ga_dry || return 0
    [ -n "${GOAMNEZIA_KMOD_ETC:-}" ] && [ -n "${GOAMNEZIA_KMOD_SRC_ROOT:-}" ] && [ -n "${GOAMNEZIA_KMOD_LIBMOD:-}" ]
}
_ga_kmod_host_ok() {
    _ga_kmod_host_paths_ok && return 0
    ga_err kmod_dry_unsafe "$(t kmod_err_dry_unsafe)" 2
}

# ── Состояние: state/kmod.json ────────────────────────────────────────────────
# {want: kernel|program, installed, owner, version, kernels[], pkgs[], p218, modules_load, hooks, at,
#  selftest: {ok, kernel, label, at, cases[]}, failed: {kernel, step, code, reason, left, boot, log, at},
#  fallback: {kernel, reason, boot, at}, rebuild: {label, kernel, at, ok}, removed_at}
_ga_kmod_state() {
    local f
    f=$(ga_kmod_state_file)
    if [ -f "$f" ]; then
        jq -c 'if type == "object" then . else {} end' "$f" 2>/dev/null && return 0
    fi
    printf '{}'
}
# _ga_kmod_state_get <jq-путь> → значение (пусто — нет; false печатается словом).
_ga_kmod_state_get() { _ga_kmod_state | jq -r "($1) | if . == null then empty else . end" 2>/dev/null; }
# _ga_kmod_state_edit <фильтр jq> [--arg …] — переписать состояние атомарно (_ga_write_json).
_ga_kmod_state_edit() {
    local filter="$1" new
    shift
    new=$(_ga_kmod_state | jq -c "$@" "$filter" 2>/dev/null) || return 1
    [ -n "$new" ] || return 1
    mkdir -p "$(dirname "$(ga_kmod_state_file)")" 2>/dev/null
    printf '%s' "$new" | _ga_write_json "$(ga_kmod_state_file)"
}

# ga_kmod_want → kernel | program | пусто (человек не выбирал).
ga_kmod_want() {
    local w
    w=$(_ga_kmod_state_get '.want')
    case "$w" in kernel|program) printf '%s' "$w" ;; esac
    return 0
}

# ── Ход долгого действия: файл в /run и записи в журнал действий ───────────────
# kmod-status отдаёт его полем progress (бот и панель показывают ход, пока мост занят); после конца файла нет.
_ga_kmod_progress() {
    local action="$1" step="$2" text="${3:-}" f started
    f=$(_ga_kmod_progress_file)
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    started=$(jq -r '.started // empty' "$f" 2>/dev/null) || started=""
    [ -n "$started" ] || started=$(ga_now)
    # pid — процесс моста или меню ($$ и в подоболочке — он же): умер процесс — хода нет, файл забытый.
    jq -cn --arg a "$action" --arg s "$step" --arg x "$text" --arg at "$(ga_now)" --arg st "$started" \
        --argjson pid "$$" '{action: $a, step: $s, text: $x, at: $at, started: $st, pid: $pid}' \
        2>/dev/null >"$f.tmp" && mv -f "$f.tmp" "$f" 2>/dev/null
    chmod 600 "$f" 2>/dev/null || true
    [ -n "$text" ] && log_info "$text"
    log_to_file "kmod-$action: $step${text:+ — $text}"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "kmod-$action" "step=$step"
    return 0
}
_ga_kmod_progress_done() { rm -f "$(_ga_kmod_progress_file)" 2>/dev/null; return 0; }
# ga_kmod_progress_json → {action, step, text, at, started} или null (нет действия или его процесс уже умер).
ga_kmod_progress_json() {
    local f pid
    f=$(_ga_kmod_progress_file)
    [ -f "$f" ] || { printf 'null'; return 0; }
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null) || pid=""
    if ! [[ "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then printf 'null'; return 0; fi
    jq -c '{action, step, text, at, started}' "$f" 2>/dev/null || printf 'null'
}
# _ga_kmod_busy — идёт долгое действие ДРУГОГО процесса (своё — не помеха: удаление переводит профили на программу,
# пересборка — туда и обратно).
_ga_kmod_busy() {
    local f pid
    f=$(_ga_kmod_progress_file)
    [ -f "$f" ] || return 1
    pid=$(jq -r '.pid // empty' "$f" 2>/dev/null) || pid=""
    [[ "$pid" =~ ^[0-9]+$ ]] && [ "$pid" != "$$" ] && kill -0 "$pid" 2>/dev/null
}

# ── Факты о модуле ────────────────────────────────────────────────────────────
ga_kmod_label_ok() { [[ "${1:-}" =~ $GA_KMOD_PATCH_RE ]]; }
# ga_kmod_loaded_version → версия модуля amneziawg в памяти (rc 1 — не загружен).
ga_kmod_loaded_version() {
    local d
    d=$(ga_kmod_sys_dir)
    [ -d "$d" ] || return 1
    head -c 128 "$d/version" 2>/dev/null | tr -cd 'A-Za-z0-9.+_~-'
}
# ga_kmod_ko_file <ядро> → файл модуля для этого ядра (DKMS кладёт в updates/dkms) или rc 1.
ga_kmod_ko_file() {
    local k="${1:-}" d f root
    [ -n "$k" ] || return 1
    root="$(_ga_kmod_libmod)/$k"
    for d in updates/dkms updates extra kernel/net kernel/drivers/net; do
        for f in "$root/$d"/amneziawg.ko "$root/$d"/amneziawg.ko.{zst,xz,gz}; do
            [ -f "$f" ] && { printf '%s' "$f"; return 0; }
        done
    done
    return 1
}
# ga_kmod_ko_version <ядро> → версия файла модуля (modinfo); пусто — файла нет.
ga_kmod_ko_version() {
    local f
    f=$(ga_kmod_ko_file "${1:-}") || return 1
    modinfo -F version "$f" 2>/dev/null | head -n 1 | tr -cd 'A-Za-z0-9.+_~-'
}
_ga_kmod_ours_src() { [ -f "$(ga_kmod_src_dir)/.goamnezia" ]; }
# Сосед Kaskad (NEIGHBOURS.md): его хуки или состояние модуля на месте.
ga_kmod_kaskad_present() {
    [ -f "$(_ga_kmod_etc)/kernel/postinst.d/zz-kaskad-amneziawg" ] || [ -f "$(_ga_kmod_etc)/kaskad/gw/awg-kmod.json" ]
}
# ga_kmod_kaskad_uses — сосед пользуется модулем: "enabled": true в /etc/kaskad/gw/awg-kmod.json или его интерфейсы
# kgw-awg*/kawg* в памяти. Тогда модуль не выгружаем и DKMS не трогаем — только своё.
ga_kmod_kaskad_uses() {
    local f
    f="$(_ga_kmod_etc)/kaskad/gw/awg-kmod.json"
    [ -f "$f" ] && [ "$(jq -r '.enabled // false' "$f" 2>/dev/null)" = true ] && return 0
    ip -o link show 2>/dev/null | awk -F': ' '{print $2}' | sed 's/@.*//' | grep -Eq '^(kgw-awg|kawg)'
}
# ga_kmod_owner → goamnezia (исходники с нашей отметкой) | kaskad | other (модуль есть, чей — не наш) | пусто.
ga_kmod_owner() {
    local k
    if _ga_kmod_ours_src; then printf 'goamnezia'; return 0; fi
    if ga_kmod_kaskad_present; then printf 'kaskad'; return 0; fi
    k=$(ga_kmod_kernel)
    if ga_kmod_ko_file "$k" >/dev/null || ga_kmod_loaded_version >/dev/null; then printf 'other'; fi
    return 0
}

# ── Профили, которые переводятся ──────────────────────────────────────────────
# ga_kmod_profiles → установленные профили на awg0 в порядке перевода (awg2, awg1, awg3). Подхваченный старый
# контейнер приложения на wg0 (образ amnezia-wg, прежний wg-quick) модуль AmneziaWG не подхватит — его не переводим.
ga_kmod_profiles() {
    local list p out=""
    ga_profiles_load list || return 1
    for p in $GA_KMOD_ORDER; do
        grep -qx -- "$p" <<<"$list" || continue
        [ "$(ga_amn_iface "$p")" = awg0 ] || continue
        out+="$p "
    done
    printf '%s' "${out% }"
}
ga_kmod_profile_want() {
    local v
    v=$(head -n 1 "$(ga_amn_state_dir "$1")/engine" 2>/dev/null | tr -cd 'a-z')
    case "$v" in kernel|program) printf '%s' "$v" ;; esac
    return 0
}

# ── Блок движка в start.sh (KMOD-06, Б9) ─────────────────────────────────────
# POSIX sh без башизмов: goWARP проверяет start.sh `sh -n` (busybox ash) и вставляет свой блок перед строкой
# `tail -f /dev/null` или первой строкой, начинающейся с `exit`, — таких строк в блоке нет; строка изоляции встаёт
# перед первой строкой, начинающейся с `iptables` или `tail`, — их в блоке тоже нет (всё с отступом).
ga_kmod_engine_block() {
    cat <<'EOF'
# --- goamnezia-engine BEGIN ---
# goAmnezia: движок AmneziaWG. /opt/amnezia/awg/engine = program — программа amneziawg-go, даже когда на хосте
# загружен модуль ядра (awg-quick выбрал бы его сам); иначе — awg-quick, как у приложения Amnezia.
if [ -f /opt/amnezia/awg/awg0.conf ]; then
  if [ "$(cat /opt/amnezia/awg/engine 2>/dev/null)" = program ]; then
    ip link del dev awg0 2>/dev/null
    amneziawg-go awg0
    awg-quick strip /opt/amnezia/awg/awg0.conf | awg setconf awg0 /dev/stdin
    for ga_a in $(sed -n 's/^[[:space:]]*Address[[:space:]]*=//p' /opt/amnezia/awg/awg0.conf | tr ',' ' '); do
      ip address add "$ga_a" dev awg0
    done
    ga_m=$(sed -n 's/^[[:space:]]*MTU[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' /opt/amnezia/awg/awg0.conf | head -n 1)
    if [ -z "$ga_m" ]; then
      ga_d=$(ip route show default 2>/dev/null | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -n 1)
      ga_m=$(( $(cat "/sys/class/net/${ga_d:-eth0}/mtu" 2>/dev/null || echo 1500) - 80 ))
    fi
    ip link set dev awg0 mtu "$ga_m" up
    awg show awg0 allowed-ips 2>/dev/null | while read -r ga_k ga_ips; do
      for ga_r in $ga_ips; do
        case "$ga_r" in */0|'(none)') continue ;; */*) ;; *) continue ;; esac
        case "$ga_r" in *:*) ga_f=-6 ;; *) ga_f=-4 ;; esac
        [ -n "$(ip $ga_f route show dev awg0 match "$ga_r" 2>/dev/null)" ] || ip $ga_f route add "$ga_r" dev awg0
      done
    done
  else
    (awg-quick up /opt/amnezia/awg/awg0.conf)
  fi
fi
# --- goamnezia-engine END ---
EOF
}

# ga_kmod_start_sh_engine <текст start.sh> → тот же текст, где строка подъёма приложения («awg-quick up») заменена
# блоком движка; блок прежней версии — на нынешний. Остальные строки — блок goWARP, изоляция, правки приложения — как
# были. Повтор ничего не меняет. rc 2 — строки подъёма нет (start.sh не узнан) или у блока нет конца.
ga_kmod_start_sh_engine() {
    local text="$1" block nb ne
    nb=$(grep -cxF -- "$GA_KMOD_BLOCK_BEGIN" <<<"$text")
    ne=$(grep -cxF -- "$GA_KMOD_BLOCK_END" <<<"$text")
    [ "$nb" = "$ne" ] && [ "$nb" -le 1 ] || return 2
    block=$(ga_kmod_engine_block)
    printf '%s\n' "$text" | GA_KMOD_BLOCK="$block" awk -v b="$GA_KMOD_BLOCK_BEGIN" -v e="$GA_KMOD_BLOCK_END" \
        -v up="$GA_KMOD_UP_LINE" '
        BEGIN { blk = ENVIRON["GA_KMOD_BLOCK"]; done = 0; skip = 0 }
        skip { if ($0 == e) skip = 0; next }
        !done && $0 == b { print blk; done = 1; skip = 1; next }
        { t = $0; sub(/^[ \t]+/, "", t); sub(/[ \t\r]+$/, "", t) }
        !done && t == up { print blk; done = 1; next }
        { print }
        END { if (!done) exit 2 }'
}

# ga_kmod_engine_write <профиль> <kernel|program> — желаемый движок: файл в контейнере (/opt/amnezia/awg/engine) и в
# копии state/, блок в start.sh (правка на месте живого start.sh: блок goWARP, изоляция и правки приложения целы).
# Без перезапуска: движок меняется при следующем старте контейнера. Контейнера нет — только копия (её вернёт
# восстановление).
ga_kmod_engine_write() {
    local p="$1" eng="$2" c sdir live="" new st
    case "$eng" in kernel|program) ;; *) ga_err kmod_bad_engine "$(tf kmod_err_bad_engine "$eng")" 2; return 2 ;; esac
    c=$(ga_profile_field "$p" container)
    sdir=$(ga_amn_state_dir "$p")
    ga_amn_state_init "$sdir" || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }
    ga_capture st docker_container_state "$c"
    if [ "$st" = running ] || [ "$st" = exited ]; then
        live=$(docker_read_file_any "$c" "$GA_START_SH" 2>/dev/null) || live=""
    fi
    [ -n "$live" ] || live=$(cat "$sdir/start.sh" 2>/dev/null) || live=""
    if [ -z "$live" ]; then
        ga_err kmod_start_sh_missing "$(tf kmod_err_start_sh "$p")" 3
        return 3
    fi
    if ! new=$(ga_kmod_start_sh_engine "$live"); then
        ga_err kmod_start_sh_unknown "$(tf kmod_err_start_sh "$p")" 2
        return 2
    fi
    if [ "$st" = running ] || [ "$st" = exited ]; then
        if [ "$new" != "$live" ]; then
            printf '%s\n' "$new" | docker_write_file "$c" "$GA_START_SH" 0755 || return 1
        fi
        printf '%s\n' "$eng" | docker_write_file "$c" "$GA_KMOD_ENGINE_PATH" 0600 || return 1
    fi
    printf '%s\n' "$new" | ga_amn_write_secret "$sdir/start.sh" || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }
    printf '%s\n' "$eng" | ga_amn_write_secret "$sdir/engine" || { ga_err state_failed "$(tf amnezia_err_state "$sdir")"; return 1; }
    return 0
}

# ga_kmod_engine_seed <профиль> — новый профиль (ga_amn_write_start_sh) получает выбранный на сервере движок до
# первого старта: модуль в памяти иначе подхватил бы его сам. Человек не выбирал (want пуст) — ничего.
ga_kmod_engine_seed() {
    local p="$1" w
    w=$(ga_kmod_want)
    [ -n "$w" ] || return 0
    [ "$(ga_amn_iface "$p")" = awg0 ] || return 0
    [ -n "$(ga_kmod_profile_want "$p")" ] && return 0
    ga_kmod_engine_write "$p" "$w" >/dev/null || log_warning "$(tf kmod_warn_seed_failed "$p")"
    return 0
}

# ── Движок профилей: кэш фактического (чтобы status не ходил в Docker) ─────────
# /run/goamnezia/kmod-engines.json {boot, at, profiles: {awg2: {engine, at}}}. Обновляют перевод, сторож (раз в
# 10 минут и сразу после перезагрузки) и profiles-status (живой опрос).
_ga_kmod_engines_cache() { jq -c 'if type == "object" then . else {} end' "$(_ga_kmod_engines_file)" 2>/dev/null || printf '{}'; }
_ga_kmod_engines_put() {
    local p="$1" eng="$2" f old
    f=$(_ga_kmod_engines_file)
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 0
    old=$(_ga_kmod_engines_cache)
    jq -cn --argjson o "$old" --arg p "$p" --arg e "$eng" --arg b "$(_ga_kmod_boot_id)" --argjson now "$(_ga_kmod_now)" \
        '$o + {boot: $b, at: $now} | .profiles = ((.profiles // {}) + {($p): {engine: $e, at: $now}})' \
        2>/dev/null >"$f.tmp" && mv -f "$f.tmp" "$f" 2>/dev/null
    chmod 600 "$f" 2>/dev/null || true
    return 0
}
# ga_kmod_engine_now <профиль> [live] → фактический движок: kernel | program | unknown | stopped. Модуля в памяти нет
# (amneziawg, а у старого контейнера приложения на wg0 — wireguard) — program без похода в Docker; без live — из кэша,
# если он свежий (10 минут, та же загрузка).
ga_kmod_engine_now() {
    local p="$1" live="${2:-}" c st eng="" cache at boot now mod=amneziawg
    case "$(ga_amn_iface "$p")" in wg*) mod=wireguard ;; esac
    if [ ! -d "${GOAMNEZIA_SYS_MODULE_DIR:-/sys/module}/$mod" ]; then
        printf 'program'
        return 0
    fi
    c=$(ga_profile_field "$p" container)
    if [ "$live" != live ]; then
        cache=$(_ga_kmod_engines_cache)
        boot=$(jq -r '.boot // ""' <<<"$cache")
        at=$(jq -r --arg p "$p" '.profiles[$p].at // 0' <<<"$cache")
        eng=$(jq -r --arg p "$p" '.profiles[$p].engine // ""' <<<"$cache")
        now=$(_ga_kmod_now)
        [[ "$at" =~ ^[0-9]+$ ]] || at=0
        if [ -n "$eng" ] && [ "$boot" = "$(_ga_kmod_boot_id)" ] && [ $((now - at)) -lt 600 ]; then
            printf '%s' "$eng"; return 0
        fi
    fi
    st=$(docker_container_state "$c" 2>/dev/null)
    if [ "$st" != running ]; then printf 'stopped'; return 0; fi
    eng=$(ga_amn_engine "$p")
    _ga_kmod_engines_put "$p" "$eng"
    printf '%s' "$eng"
}

# ga_kmod_profiles_enrich <JSON-массив профилей> [live] → тот же массив, у каждого engine (фактический) и engine_want
# (выбранный: kernel | program | пусто). profiles-status — с live (живой опрос), status — из кэша.
ga_kmod_profiles_enrich() {
    local arr="$1" live="${2:-}" p eng want map='{}'
    for p in $(jq -r '.[]?.profile // empty' <<<"$arr" 2>/dev/null); do
        eng=$(ga_kmod_engine_now "$p" "$live")
        want=$(ga_kmod_profile_want "$p")
        map=$(jq -c --arg p "$p" --arg e "$eng" --arg w "$want" '. + {($p): {engine: $e, engine_want: $w}}' <<<"$map")
    done
    jq -c --argjson m "$map" 'map(. + ($m[.profile] // {}))' <<<"$arr" 2>/dev/null || printf '%s' "$arr"
}

# ── Проверка хоста (Б2) ──────────────────────────────────────────────────────
_ga_kmod_virt() {
    local v=""
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        v=$(systemd-detect-virt -c 2>/dev/null | head -n 1 | tr -cd 'a-z0-9_-')
    else
        v=$(tr '\0' '\n' <"$(_ga_kmod_proc)/1/environ" 2>/dev/null | sed -n 's/^container=//p' | head -n 1 | tr -cd 'a-z0-9_-')
    fi
    printf '%s' "${v:-none}"
}
# _ga_kmod_secure_boot → true | false: mokutil, а без него — переменная EFI SecureBoot (пятый байт = 1).
_ga_kmod_secure_boot() {
    local out f b
    if command -v mokutil >/dev/null 2>&1; then
        out=$(mokutil --sb-state 2>/dev/null) || out=""
        if grep -qi 'SecureBoot enabled' <<<"$out"; then printf true; return 0; fi
        if grep -qi 'SecureBoot disabled' <<<"$out"; then printf false; return 0; fi
    fi
    for f in "$(_ga_kmod_efivars)"/SecureBoot-*; do
        [ -f "$f" ] || continue
        b=$(od -An -t u1 -j 4 -N 1 "$f" 2>/dev/null | tr -cd '0-9')
        [ "$b" = 1 ] && { printf true; return 0; }
    done
    printf false
}
_ga_kmod_kernel_ok() {
    local k="$1" maj min
    [[ "$k" =~ ^([0-9]+)\.([0-9]+) ]] || return 1
    maj="${BASH_REMATCH[1]}"; min="${BASH_REMATCH[2]}"
    [ "$maj" -gt 5 ] || { [ "$maj" -eq 5 ] && [ "$min" -ge 4 ]; }
}
# _ga_kmod_headers_candidate <пакет> → версия-кандидат apt (пусто — нет).
_ga_kmod_headers_candidate() {
    apt-cache policy "$1" 2>/dev/null | sed -n 's/^[[:space:]]*Candidate:[[:space:]]*//p' | head -n 1 | grep -v '^(none)$' || true
}
_ga_kmod_pkg_installed() { dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed'; }
_ga_kmod_gcc_pkg() {
    local n
    n=$(sed -n 's/.*gcc-\([0-9][0-9]*\).*/\1/p' "$(_ga_kmod_proc)/version" 2>/dev/null | head -n 1)
    [ -n "$n" ] && printf 'gcc-%s' "$n"
}
# _ga_kmod_flavour <ядро> → generic | kvm | amd64 | cloud-amd64 … (метапакет заголовков того же семейства).
_ga_kmod_flavour() { sed -E 's/^[0-9]+(\.[0-9]+)*-[0-9]+(\.[0-9]+)*-//' <<<"$1" | grep -E '^[a-z][a-z0-9-]*$' || true; }
# _ga_kmod_apt_sim <пакеты…> → JSON {pkgs: [что встанет], kernel: тянет ли новое ядро, size_mb}. Только симуляция.
_ga_kmod_apt_sim() {
    local sim pk size=0 kb kern=false
    [ $# -gt 0 ] || { printf '{"pkgs":[],"kernel":false,"size_mb":0}'; return 0; }
    sim=$(LANG=C apt-get -s -o Debug::NoLocking=1 install "$@" 2>/dev/null) || sim=""
    pk=$(sed -n 's/^Inst \([^ ]*\).*/\1/p' <<<"$sim")
    grep -Eq '^(linux-image-|linux-modules-)' <<<"$pk" && kern=true
    if [ -n "$pk" ]; then
        # shellcheck disable=SC2086
        for kb in $(apt-cache show --no-all-versions $pk 2>/dev/null | sed -n 's/^Installed-Size:[[:space:]]*\([0-9][0-9]*\).*/\1/p'); do
            size=$((size + kb))
        done
    fi
    jq -cn --arg p "$pk" --argjson k "$kern" --argjson s "$(( (size + 1023) / 1024 ))" \
        '{pkgs: ($p | split("\n") | map(select(. != ""))), kernel: $k, size_mb: $s}'
}

# ga_kmod_check_json [plan] → проверка хоста {ok, code, reason, arch, virt, secure_boot, disk_free_mb, kernel,
# kernel_ok, headers {installed, candidate}, module {loaded, version, installed, ko_version, owner}, kaskad, reuse,
# plan {missing[], install[], size_mb, kernel, gcc, headers_meta {name, installed, kernel, size_mb}} | null}.
# reason — одной фразой с причиной и что сделать (рецепт §1, §13). plan — только с аргументом plan (apt-get -s).
ga_kmod_check_json() {
    local want_plan="${1:-}" arch virt sb disk k kok=false hinst=false hcand="" code="" reason="" ok=true
    local loaded=false lver="" kover="" reuse=false owner plan=null
    arch=$(_ga_kmod_arch)
    virt=$(_ga_kmod_virt)
    sb=$(_ga_kmod_secure_boot)
    disk=$(ga_df_mb / 2>/dev/null | awk '{print $3}')
    [[ "$disk" =~ ^[0-9]+$ ]] || disk=-1
    k=$(ga_kmod_kernel)
    _ga_kmod_kernel_ok "$k" && kok=true
    [ -d "$(_ga_kmod_libmod)/$k/build" ] && hinst=true
    lver=$(ga_kmod_loaded_version 2>/dev/null) && loaded=true
    kover=$(ga_kmod_ko_version "$k" 2>/dev/null) || kover=""
    # Модуль с меткой набора под это ядро уже стоит (сосед Kaskad или прошлая установка): сборки не будет —
    # заголовки, компилятор и место не нужны.
    ga_kmod_label_ok "$kover" && reuse=true
    owner=$(ga_kmod_owner)
    if ! command -v apt-get >/dev/null 2>&1; then
        code=not_apt; reason=$(t kmod_why_not_apt)
    elif [ "$arch" != x86_64 ] && [ "$arch" != aarch64 ]; then
        code=arch; reason=$(tf kmod_why_arch "${arch:-?}")
    elif [ "$virt" != none ]; then
        code=container; reason=$(tf kmod_why_container "$(_ga_kmod_virt_name "$virt")")
    elif [ ! -e "$(_ga_kmod_proc)/modules" ]; then
        code=no_proc_modules; reason=$(t kmod_why_no_modules)
    elif [ "$sb" = true ]; then
        code=secure_boot; reason=$(t kmod_why_secure_boot)
    elif [ "$kok" != true ]; then
        code=kernel_old; reason=$(tf kmod_why_kernel_old "$k")
    elif [ "$reuse" != true ] && [ "$disk" -ge 0 ] && [ "$disk" -lt "$GA_KMOD_MIN_DISK_MB" ]; then
        code=disk; reason=$(tf kmod_why_disk "$disk" "$GA_KMOD_MIN_DISK_MB")
    elif [ "$reuse" != true ] && [ "$hinst" != true ]; then
        hcand=$(_ga_kmod_headers_candidate "linux-headers-$k")
        if [ -z "$hcand" ]; then code=no_headers; reason=$(tf kmod_why_no_headers "$k"); fi
    fi
    [ -z "$code" ] || ok=false
    if [ "$ok" = true ] && [ "$want_plan" = plan ] && [ "$reuse" != true ]; then
        plan=$(_ga_kmod_plan_json "$k")
    fi
    jq -cn --argjson ok "$ok" --arg code "$code" --arg reason "$reason" --arg arch "$arch" --arg virt "$virt" \
        --argjson sb "$sb" --argjson disk "$disk" --arg k "$k" --argjson kok "$kok" --argjson hi "$hinst" \
        --arg hc "$hcand" --argjson loaded "$loaded" --arg lver "$lver" --arg kover "$kover" --arg owner "$owner" \
        --argjson kaskad "$(ga_kmod_kaskad_present && echo true || echo false)" --argjson reuse "$reuse" \
        --argjson plan "$plan" --arg lbl "$GA_KMOD_LABEL" \
        '{ok: $ok, code: $code, reason: $reason, arch: $arch, virt: $virt, secure_boot: $sb, disk_free_mb: $disk,
          kernel: $k, kernel_ok: $kok, headers: {installed: $hi, candidate: $hc},
          module: {loaded: $loaded, version: $lver, installed: ($kover != ""), ko_version: $kover, owner: $owner},
          kaskad: $kaskad, reuse: $reuse, label: $lbl, plan: $plan}'
}
_ga_kmod_virt_name() {
    case "$1" in
        lxc|lxc-libvirt) printf 'LXC' ;;
        openvz) printf 'OpenVZ' ;;
        docker) printf 'Docker' ;;
        podman) printf 'Podman' ;;
        wsl) printf 'WSL' ;;
        systemd-nspawn) printf 'systemd-nspawn' ;;
        *) printf '%s' "$1" ;;
    esac
}

# _ga_kmod_plan_json <ядро> → что apt поставит: недостающее из dkms gcc make patch gcc-NN linux-headers-<ядро>, сколько
# места, и метапакет заголовков своего семейства (KMOD-05: если он тянет новое ядро — отдельно, с размером).
_ga_kmod_plan_json() {
    local k="$1" gcc p fl meta="" mjs=null sim
    local -a want=(dkms gcc make patch) missing=()
    gcc=$(_ga_kmod_gcc_pkg)
    [ -n "$gcc" ] && want+=("$gcc")
    [ -d "$(_ga_kmod_libmod)/$k/build" ] || want+=("linux-headers-$k")
    for p in "${want[@]}"; do _ga_kmod_pkg_installed "$p" || missing+=("$p"); done
    sim=$(_ga_kmod_apt_sim "${missing[@]}")
    fl=$(_ga_kmod_flavour "$k")
    if [ -n "$fl" ]; then
        meta="linux-headers-$fl"
        if _ga_kmod_pkg_installed "$meta"; then
            mjs=$(jq -cn --arg n "$meta" '{name: $n, installed: true, kernel: false, size_mb: 0}')
        elif [ -n "$(_ga_kmod_headers_candidate "$meta")" ]; then
            mjs=$(_ga_kmod_apt_sim "$meta" | jq -c --arg n "$meta" '{name: $n, installed: false, kernel: .kernel, size_mb: .size_mb}')
        fi
    fi
    jq -cn --argjson sim "$sim" --arg gcc "$gcc" --argjson meta "${mjs:-null}" \
        --arg miss "$(printf '%s\n' "${missing[@]+"${missing[@]}"}")" \
        '{missing: ($miss | split("\n") | map(select(. != ""))), install: $sim.pkgs, size_mb: $sim.size_mb,
          kernel: $sim.kernel, gcc: $gcc, headers_meta: $meta}'
}

# ── Пакеты: ожидание apt с ходом в строках ────────────────────────────────────
_ga_kmod_apt_busy() {
    fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 && return 0
    fuser /var/lib/dpkg/lock >/dev/null 2>&1 && return 0
    fuser /var/lib/apt/lists/lock >/dev/null 2>&1 && return 0
    pgrep -f '^/usr/bin/unattended-upgrade' >/dev/null 2>&1 && return 0
    return 1
}
# _ga_kmod_apt_wait [секунд] — ждать, пока apt и dpkg свободны (unattended-upgrades на свежем сервере), строкой хода раз
# в 30 с. Мост ждёт 10 минут (GA_KMOD_APT_WAIT), SSH — 30.
_ga_kmod_apt_wait() {
    local max="${1:-${GA_KMOD_APT_WAIT:-600}}" t0 now waited last=-30
    [[ "$max" =~ ^[0-9]+$ ]] || max=600
    t0=$(_ga_kmod_now)
    while _ga_kmod_apt_busy; do
        now=$(_ga_kmod_now); waited=$((now - t0))
        if [ "$waited" -ge "$max" ]; then
            ga_err apt_locked "$(tf kmod_err_apt_locked "$((max / 60))")"
            return 1
        fi
        if [ $((waited - last)) -ge 30 ]; then
            _ga_kmod_progress "${GA_KMOD_ACTION:-install}" apt_wait "$(tf kmod_apt_waiting "$((waited / 60))" "$((max / 60))")"
            last=$waited
        fi
        _ga_kmod_sleep 5
    done
    return 0
}

# _ga_kmod_packages <ядро> <headers_meta on|off> — поставить недостающее; что поставили сами — в состояние (pkgs).
_ga_kmod_packages() {
    local k="$1" meta_ok="${2:-off}" plan meta mk p before after=""
    local -a missing=() mine=()
    _ga_kmod_apt_wait || return 1
    plan=$(_ga_kmod_plan_json "$k")
    # Списков пакетов нет или устарели (свежий сервер): заголовков ядра нет среди кандидатов — apt-get update и снова.
    if [ ! -d "$(_ga_kmod_libmod)/$k/build" ] && [ -z "$(_ga_kmod_headers_candidate "linux-headers-$k")" ]; then
        apt_update >/dev/null 2>&1 || true
        plan=$(_ga_kmod_plan_json "$k")
    fi
    mapfile -t missing < <(jq -r '.missing[]?' <<<"$plan")
    meta=$(jq -r '.headers_meta.name // empty' <<<"$plan")
    mk=$(jq -r 'if .headers_meta == null then "" elif .headers_meta.installed then "installed" elif .headers_meta.kernel then "kernel" else "ok" end' <<<"$plan")
    # Метапакет заголовков: без нового ядра — ставим сам (тогда и следующее ядро соберётся); тянет ядро — только с
    # отдельным согласием (KMOD-05), иначе пропуск с причиной в ответе.
    if [ -n "$meta" ] && { [ "$mk" = ok ] || { [ "$mk" = kernel ] && [ "$meta_ok" = on ]; }; }; then
        missing+=("$meta")
    fi
    GA_KMOD_META_SKIPPED=""
    [ "$mk" = kernel ] && [ "$meta_ok" != on ] && GA_KMOD_META_SKIPPED="$meta"
    [ "${#missing[@]}" -gt 0 ] || return 0
    before=$(for p in "${missing[@]}"; do _ga_kmod_pkg_installed "$p" && printf '%s\n' "$p"; done)
    _ga_kmod_progress "${GA_KMOD_ACTION:-install}" packages "$(tf kmod_step_packages "${missing[*]}")"
    if ! apt_install "${missing[@]}"; then
        ga_err apt_install_failed "$(tf kmod_err_packages "${missing[*]}")"
        return 1
    fi
    for p in "${missing[@]}"; do
        grep -qx -- "$p" <<<"$before" && continue
        _ga_kmod_pkg_installed "$p" && mine+=("$p")
    done
    after=$(printf '%s\n' "${mine[@]+"${mine[@]}"}")
    _ga_kmod_state_edit '.pkgs = (((.pkgs // []) + ($p | split("\n") | map(select(. != "")))) | unique)' --arg p "$after"
    return 0
}

# ── Исходники и патчи (Б5) ───────────────────────────────────────────────────
# _ga_kmod_source — /usr/src/amneziawg-<тег>: архив тега, sha256 закреплён (чужой — стоп, ничего не собираем), src/
# архива, dkms.conf без AUTOINSTALL и REMAKE_INITRD, отметка .goamnezia. Уже есть с нашей отметкой — как есть.
_ga_kmod_source() {
    local src url sha want tmp top
    src=$(ga_kmod_src_dir)
    if [ -d "$src" ]; then
        if _ga_kmod_ours_src || grep -qF "+$GA_KMOD_SET" "$src/version.h" 2>/dev/null; then
            _ga_kmod_dkms_conf "$src" || return 1
            return 0
        fi
        ga_err kmod_foreign_src "$(tf kmod_err_foreign_src "$src" "$GA_KMOD_VER")" 1
        return 1
    fi
    url="${GOAMNEZIA_KMOD_URL:-$GA_KMOD_URL_DEFAULT}"
    want=$(_ga_kmod_pin GOAMNEZIA_KMOD_SHA256 "$GA_KMOD_SHA256_PIN")
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/goamnezia-kmod.XXXXXX") || { ga_err kmod_tmp_failed "$(t kmod_err_tmp)"; return 1; }
    chmod 700 "$tmp"
    _ga_kmod_progress "${GA_KMOD_ACTION:-install}" source "$(tf kmod_step_source "$GA_KMOD_TAG")"
    if ! curl -fsSL --retry 3 --connect-timeout 20 --max-time 600 -o "$tmp/src.tgz" "$url" 2>/dev/null; then
        rm -rf "$tmp"
        ga_err kmod_download_failed "$(tf kmod_err_download "$GA_KMOD_TAG")"
        return 1
    fi
    sha=$(_ga_kmod_sha256 "$tmp/src.tgz")
    if [ "$sha" != "$want" ]; then
        rm -rf "$tmp"
        ga_err kmod_sha_mismatch "$(tf kmod_err_sha "${sha:-?}" "$want")"
        return 1
    fi
    if ! tar -xzf "$tmp/src.tgz" -C "$tmp" 2>/dev/null; then
        rm -rf "$tmp"
        ga_err kmod_unpack_failed "$(t kmod_err_unpack)"
        return 1
    fi
    top="$tmp/amneziawg-linux-kernel-module-$GA_KMOD_VER/src"
    if [ ! -f "$top/dkms.conf" ]; then
        rm -rf "$tmp"
        ga_err kmod_unpack_failed "$(t kmod_err_unpack)"
        return 1
    fi
    mkdir -p "$src" && cp -a "$top/." "$src/" || { rm -rf "$tmp" "$src"; ga_err kmod_unpack_failed "$(t kmod_err_unpack)"; return 1; }
    rm -rf "$tmp"
    printf 'goamnezia %s\n' "$(ga_now)" >"$src/.goamnezia"
    _ga_kmod_dkms_conf "$src" || return 1
    return 0
}
# _ga_kmod_dkms_conf <каталог> — PACKAGE_NAME и PACKAGE_VERSION наши, строк AUTOINSTALL и REMAKE_INITRD нет вовсе
# (KMOD-09: dkms 3.0.11 считает «да» любое непустое значение — штатный хук ядра собирал модуль сам).
_ga_kmod_dkms_conf() {
    local f="$1/dkms.conf" tmp
    [ -f "$f" ] || { ga_err kmod_unpack_failed "$(t kmod_err_unpack)"; return 1; }
    tmp=$(mktemp "$f.XXXXXX") || return 1
    awk -v v="$GA_KMOD_VER" '
        /^[[:space:]]*(AUTOINSTALL|REMAKE_INITRD)[[:space:]]*=/ { next }
        /^[[:space:]]*PACKAGE_NAME[[:space:]]*=/ { print "PACKAGE_NAME=\"amneziawg\""; n = 1; next }
        /^[[:space:]]*PACKAGE_VERSION[[:space:]]*=/ { print "PACKAGE_VERSION=\"" v "\""; ver = 1; next }
        { print }
        END { if (!n) print "PACKAGE_NAME=\"amneziawg\""; if (!ver) print "PACKAGE_VERSION=\"" v "\"" }' "$f" >"$tmp" \
        && chmod 644 "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; return 1; }
}
# _ga_kmod_needs_218 <ядро> — заголовки ядра объявляют новую сигнатуру (KMOD-04: решаем по ним, а не по номеру ядра).
_ga_kmod_needs_218() {
    local h
    for h in "$(_ga_kmod_libmod)/$1/build/include/net/udp_tunnel.h" "$(_ga_kmod_libmod)/$1/source/include/net/udp_tunnel.h"; do
        [ -f "$h" ] || continue
        grep -Eq "$GA_KMOD_218_RE" "$h"
        return $?
    done
    return 1
}
_ga_kmod_patch_check() {   # <файл> <закреплённый sha256>
    local got
    got=$(_ga_kmod_sha256 "$1")
    [ -n "$got" ] && [ "$got" = "$2" ] && return 0
    ga_err kmod_patch_sha "$(tf kmod_err_patch_sha "$(basename "$1")")" 1
}
# _ga_kmod_patches <ядро> — #218 (по заголовкам), затем набор: --dry-run, потом наложение. Набор не лёг — стоп:
# стоковый модуль опаснее программы (#253), его не ставим.
_ga_kmod_patches() {
    local k="$1" src pd p218 p31
    src=$(ga_kmod_src_dir); pd=$(_ga_kmod_patch_dir)
    p218="$pd/awg-kmod-218.patch"; p31="$pd/awg-kmod-31.patch"
    _ga_kmod_patch_check "$p218" "$(_ga_kmod_pin GOAMNEZIA_KMOD_PATCH_218_SHA "$GA_KMOD_PATCH_218_SHA")" || return 1
    _ga_kmod_patch_check "$p31" "$(_ga_kmod_pin GOAMNEZIA_KMOD_PATCH_31_SHA "$GA_KMOD_PATCH_31_SHA")" || return 1
    GA_KMOD_P218=false
    if grep -q __compat_setup_udp_tunnel_sock "$src/compat/compat.h" 2>/dev/null; then
        GA_KMOD_P218=true
    elif _ga_kmod_needs_218 "$k"; then
        _ga_kmod_progress "${GA_KMOD_ACTION:-install}" patch218 "$(tf kmod_step_218 "$k")"
        if ! (cd "$src" && patch -p2 -N --dry-run <"$p218" >/dev/null 2>&1 && patch -p2 -N <"$p218" >/dev/null 2>&1); then
            ga_err kmod_patch_failed "$(tf kmod_err_patch "awg-kmod-218.patch" "$k")"
            return 1
        fi
        GA_KMOD_P218=true
    fi
    grep -qF "+$GA_KMOD_SET" "$src/version.h" 2>/dev/null && return 0
    _ga_kmod_progress "${GA_KMOD_ACTION:-install}" patch "$(tf kmod_step_patch "$GA_KMOD_SET")"
    if ! (cd "$src" && patch -p2 -N --dry-run <"$p31" >/dev/null 2>&1 && patch -p2 -N <"$p31" >/dev/null 2>&1); then
        ga_err kmod_patch_failed "$(tf kmod_err_patch "awg-kmod-31.patch" "$k")"
        return 1
    fi
    return 0
}

# ── Сборка, загрузка, хуки (Б6) ──────────────────────────────────────────────
# _ga_kmod_make_log <ядро> → хвост журнала сборки DKMS (KMOD-07: у dkms 3.0.11 он в <ядро>/<арх>/log/make.log).
_ga_kmod_make_log() {
    local k="$1" f
    for f in "$(_ga_kmod_dkmstree)/amneziawg/$GA_KMOD_VER/$k/$(_ga_kmod_arch)/log/make.log" \
             "$(_ga_kmod_dkmstree)/amneziawg/$GA_KMOD_VER/build/make.log"; do
        [ -f "$f" ] && { tail -n 12 "$f" 2>/dev/null | cut -c1-200; return 0; }
    done
    return 0
}
_ga_kmod_build() {
    local k="$1" ver
    if ! dkms status -m amneziawg -v "$GA_KMOD_VER" 2>/dev/null | grep -q .; then
        dkms add -m amneziawg -v "$GA_KMOD_VER" >/dev/null 2>&1 \
            || { ga_err kmod_build_failed "$(tf kmod_err_build "$k" "$(t kmod_err_dkms_add)")"; return 1; }
    fi
    _ga_kmod_progress "${GA_KMOD_ACTION:-install}" build "$(tf kmod_step_build "$k")"
    if ! dkms build -m amneziawg -v "$GA_KMOD_VER" -k "$k" --force >/dev/null 2>&1; then
        GA_KMOD_BUILD_LOG=$(_ga_kmod_make_log "$k")
        ga_err kmod_build_failed "$(tf kmod_err_build "$k" "$(tail -n 1 <<<"${GA_KMOD_BUILD_LOG:-?}")")"
        return 1
    fi
    if ! dkms install -m amneziawg -v "$GA_KMOD_VER" -k "$k" --force >/dev/null 2>&1; then
        ga_err kmod_build_failed "$(tf kmod_err_build "$k" "dkms install")"
        return 1
    fi
    ver=$(ga_kmod_ko_version "$k")
    if ! ga_kmod_label_ok "$ver"; then
        ga_err kmod_label "$(tf kmod_err_label "${ver:-?}" "$GA_KMOD_LABEL")"
        return 1
    fi
    return 0
}
# _ga_kmod_load <ядро> — модуль с меткой в памяти. Старый (другая версия) выгружается, если на нём никого нет; есть —
# kmod_in_use (сначала «Вернуть программу»; пересборка делает это сама, ga_kmod_rebuild_swap).
_ga_kmod_load() {
    local k="$1" want cur
    want=$(ga_kmod_ko_version "$k")
    cur=$(ga_kmod_loaded_version 2>/dev/null) || cur=""
    if [ -n "$cur" ] && [ "$cur" != "$want" ]; then
        if ! modprobe -r amneziawg >/dev/null 2>&1; then
            ga_err kmod_in_use "$(tf kmod_err_in_use "$cur")"
            return 1
        fi
        cur=""
    fi
    if [ -z "$cur" ]; then
        _ga_kmod_progress "${GA_KMOD_ACTION:-install}" load "$(t kmod_step_load)"
        modprobe amneziawg >/dev/null 2>&1 || { ga_err kmod_load_failed "$(tf kmod_err_load "$k")"; return 1; }
    fi
    cur=$(ga_kmod_loaded_version 2>/dev/null) || cur=""
    if ! ga_kmod_label_ok "$cur"; then
        ga_err kmod_label "$(tf kmod_err_label "${cur:-?}" "$GA_KMOD_LABEL")"
        return 1
    fi
    return 0
}
# Хук нового ядра: тот же для postinst.d и header_postinst.d — собирает тот, кто пришёл вторым (есть и образ, и
# заголовки). Никогда не валит apt: всё под «|| true», выход 0.
_ga_kmod_hook_text() {
    cat <<EOF
#!/bin/sh
# goAmnezia pro: модуль ядра AmneziaWG $GA_KMOD_VER для нового ядра (docs/KMOD_PLAN.md, этап Б). apt не валит никогда.
k="\${1:-}"
v=$GA_KMOD_VER
src=$(ga_kmod_src_dir)
p218=$(_ga_kmod_patch_dir)/awg-kmod-218.patch
[ -n "\$k" ] && [ -d "\$src" ] && command -v dkms >/dev/null 2>&1 || exit 0
[ -d "$(_ga_kmod_libmod)/\$k/build" ] || exit 0
dkms status -m amneziawg -v "\$v" -k "\$k" 2>/dev/null | grep -q installed && exit 0
{
  if ! grep -q __compat_setup_udp_tunnel_sock "\$src/compat/compat.h" 2>/dev/null && [ -f "\$p218" ]; then
    for h in "$(_ga_kmod_libmod)/\$k/build/include/net/udp_tunnel.h" "$(_ga_kmod_libmod)/\$k/source/include/net/udp_tunnel.h"; do
      [ -f "\$h" ] || continue
      if grep -Eq '$GA_KMOD_218_RE' "\$h"; then
        (cd "\$src" && patch -p2 -N --dry-run < "\$p218" >/dev/null && patch -p2 -N < "\$p218" >/dev/null)
      fi
      break
    done
  fi
  dkms build -m amneziawg -v "\$v" -k "\$k" && dkms install -m amneziawg -v "\$v" -k "\$k" --force
} >>$(_ga_kmod_hook_log) 2>&1 || true
exit 0
EOF
}
_ga_kmod_hook_log() { printf '%s' "${GOAMNEZIA_KMOD_HOOK_LOG:-/var/log/goamnezia-kmod-hook.log}"; }
_ga_kmod_hooks_install() {
    local f text
    text=$(_ga_kmod_hook_text)
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
        [ "$(cat "$f" 2>/dev/null)" = "$text" ] && continue
        printf '%s\n' "$text" >"$f.tmp" && chmod 755 "$f.tmp" && mv -f "$f.tmp" "$f" || { rm -f "$f.tmp"; return 1; }
    done < <(_ga_kmod_hook_paths)
    return 0
}
# /etc/modules-load.d/amneziawg.conf — модуль грузится до Docker. Был до нас — не наш (при удалении не трогаем).
_ga_kmod_modload_install() {
    local f
    f=$(_ga_kmod_modload_file)
    [ -f "$f" ] && return 0
    mkdir -p "$(dirname "$f")" 2>/dev/null || return 1
    printf 'amneziawg\n' >"$f" || return 1
    _ga_kmod_state_edit '.modules_load = true'
}

# ── Самопроверка до перевода (Б7) ────────────────────────────────────────────
# Одноразовый привилегированный контейнер из образа профилей (те же awg и amneziawg-go, что у профилей), в нём два
# сетевых пространства, как в тесте upstream: интерфейс модуля создаётся в gst0 и уходит в gst1 (его UDP-сокет
# остаётся в gst0 на lo), вторая сторона — в gst0: модуль или программа. Конфиги — нашим генератором с параметрами
# маскировки каждого установленного профиля (линии 1.x, 2.0, 3.1 — какие стоят): сервер — модуль ядра, клиент —
# программа (так ходят телефоны) и модуль (Linux, роутеры). Ключи одноразовые. syncconf под трафиком (#253) — никогда.
_ga_kmod_strip_conf() {   # <конфиг> [kernel] → только то, что понимает awg setconf; kernel — без I с тегами программы
    awk -v kern="${2:-}" '
        /^[[:space:]]*\[/ { sec = tolower($0); gsub(/[^a-z]/, "", sec); print; next }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        sec == "interface" && /^[[:space:]]*(Address|DNS|MTU|Table|PreUp|PostUp|PreDown|PostDown|SaveConfig)[[:space:]]*=/ { next }
        sec == "interface" && kern != "" && /^[[:space:]]*I[1-5][[:space:]]*=/ && /<d[sz]?[ >]/ { next }
        { print }' <<<"$1"
}
_ga_kmod_selftest_script() {
    local p n=0 line params spriv spub cpriv cpub psk port sconf cconf
    cat <<'EOF'
#!/bin/bash
# goAmnezia: самопроверка модуля ядра AmneziaWG (одноразовый контейнер, только сетевые пространства gst0/gst1)
st=/tmp/gst; mkdir -p "$st"; chmod 700 "$st"; cd "$st" || exit 1
gst_clean() {
  ip -n gst1 link del gta 2>/dev/null; ip -n gst0 link del gtb 2>/dev/null
  pkill -f 'amneziawg-go gtb' 2>/dev/null; rm -f /var/run/amneziawg/gtb.sock
  ip netns del gst0 2>/dev/null; ip netns del gst1 2>/dev/null
}
gst_case() {   # <id> <номер подсети> <kernel|program — клиент>
  local id=$1 n=$2 kind=$3 ok=0 hs i
  gst_clean
  ip netns add gst0 && ip netns add gst1 || { echo "CASE $id FAIL netns"; return 0; }
  ip -n gst0 link set lo up; ip -n gst1 link set lo up
  if ! ip -n gst0 link add dev gta type amneziawg 2>"$st/err"; then
    echo "CASE $id FAIL link $(tr '\n' ' ' <"$st/err" | cut -c1-120)"; gst_clean; return 0
  fi
  ip -n gst0 link set dev gta netns gst1
  if ! ip netns exec gst1 awg setconf gta "$st/$id.s" 2>"$st/err"; then
    echo "CASE $id FAIL setconf_server $(tr '\n' ' ' <"$st/err" | cut -c1-120)"; gst_clean; return 0
  fi
  ip -n gst1 address add "10.199.$n.0/24" dev gta && ip -n gst1 link set dev gta mtu 1280 up
  if [ "$kind" = kernel ]; then
    ip -n gst0 link add dev gtb type amneziawg 2>"$st/err" || { echo "CASE $id FAIL link_client"; gst_clean; return 0; }
  else
    ip netns exec gst0 amneziawg-go gtb >"$st/go.log" 2>&1 || { echo "CASE $id FAIL program"; gst_clean; return 0; }
    for i in 1 2 3 4 5 6 7 8 9 10; do [ -S /var/run/amneziawg/gtb.sock ] && break; sleep 0.3; done
  fi
  if ! ip netns exec gst0 awg setconf gtb "$st/$id.c" 2>"$st/err"; then
    echo "CASE $id FAIL setconf_client $(tr '\n' ' ' <"$st/err" | cut -c1-120)"; gst_clean; return 0
  fi
  ip -n gst0 address add "10.199.$n.2/32" dev gtb; ip -n gst0 link set dev gtb mtu 1280 up
  ip -n gst0 route add "10.199.$n.0/24" dev gtb
  for i in 1 2 3 4 5 6; do
    if ip netns exec gst0 ping -c 1 -W 2 "10.199.$n.0" >/dev/null 2>&1; then ok=$((ok + 1)); [ "$ok" -ge 2 ] && break; fi
  done
  hs=$(ip netns exec gst1 awg show gta latest-handshakes 2>/dev/null | awk '{print $2; exit}')
  if [ "${hs:-0}" -gt 0 ] 2>/dev/null && [ "$ok" -ge 1 ]; then echo "CASE $id OK ping=$ok"; else echo "CASE $id FAIL handshake=${hs:-0} ping=$ok"; fi
  gst_clean
}
echo "SELFTEST START"
EOF
    for p in $(ga_kmod_profiles); do
        n=$((n + 1))
        line=$(ga_profile_line "$p")
        params=$(ga_config_get ".profiles.$p.params" 2>/dev/null | jq -c 'if type == "object" then . else {} end' 2>/dev/null)
        [ -n "$params" ] || params='{}'
        spriv=$(ga_awgkeys genkey) && spub=$(ga_awgkeys_pubkey "$spriv") && cpriv=$(ga_awgkeys genkey) \
            && cpub=$(ga_awgkeys_pubkey "$cpriv") && psk=$(ga_awgkeys genpsk) || return 1
        port=$((51000 + 2 * n))
        sconf=$(jq -cn --argjson pa "$params" --arg k "$spriv" --arg s "10.199.$n.0/24" --argjson port "$port" \
            --arg c "$cpub" --arg psk "$psk" --arg ip "10.199.$n.2" \
            '{params: $pa, server: {privkey: $k, subnet: $s, port: $port}, peers: [{pubkey: $c, psk: $psk, ip: $ip}]}' \
            | ga_awgkeys server-conf --line "$line") || return 1
        cconf=$(jq -cn --argjson pa "$params" --arg k "$cpriv" --arg s "$spub" --argjson port "$port" --arg psk "$psk" \
            --arg n "$n" '{params: $pa, client: {ip: ("10.199." + $n + ".2/32"), privkey: $k, psk: $psk,
              allowed_ips: ("10.199." + $n + ".0/24")}, server: {pubkey: $s, endpoint_host: "127.0.0.1", port: $port},
              dns: [], mtu: "1280"}' | ga_awgkeys conf --line "$line") || return 1
        # Конфиги — в каталог одноразового контейнера; ключи одноразовые, наружу не выходят.
        printf "cat >\"\$st/%s.s\" <<'GACONF'\n%s\nGACONF\n" "${p}p" "$(_ga_kmod_strip_conf "$sconf")"
        printf "cat >\"\$st/%s.c\" <<'GACONF'\n%s\nGACONF\n" "${p}p" "$(_ga_kmod_strip_conf "$cconf")"
        printf "cat >\"\$st/%s.s\" <<'GACONF'\n%s\nGACONF\n" "${p}k" "$(_ga_kmod_strip_conf "$sconf")"
        printf "cat >\"\$st/%s.c\" <<'GACONF'\n%s\nGACONF\n" "${p}k" "$(_ga_kmod_strip_conf "$cconf" kernel)"
        printf 'gst_case %sp %s program\ngst_case %sk %s kernel\n' "$p" "$n" "$p" "$n"
    done
    printf 'echo "SELFTEST END"\n'
}

# ga_kmod_selftest → JSON {ok, kernel, label, at, cases: [{id, profile, line, client, ok, detail}], reason}; итог — и
# в состояние (selftest). Провал — kmod_selftest_failed: модуль не включается, профили остаются на программе.
ga_kmod_selftest() {
    local k label out="" img first p c js='[]' id ok line detail allok=true reason="" fx script=""
    k=$(ga_kmod_kernel)
    label=$(ga_kmod_loaded_version 2>/dev/null) || label=""
    _ga_kmod_progress "${GA_KMOD_ACTION:-install}" selftest "$(t kmod_step_selftest)"
    if ! ga_kmod_label_ok "$label"; then
        allok=false; reason=$(tf kmod_err_label "${label:-?}" "$GA_KMOD_LABEL")
    else
        first=$(ga_kmod_profiles | awk '{print $1}')
        if [ -n "$first" ]; then
            img=$(docker_container_image "$(ga_profile_field "$first" container)" | tr -d '[:space:]')
            [ -n "$img" ] || img="$(ga_profile_field "$first" container)"
            script=$(_ga_kmod_selftest_script) || { allok=false; reason=$(t kmod_err_selftest_conf); }
            if [ "$allok" = true ]; then
                if ga_dry; then
                    ga_dry_echo "docker run --rm -i --privileged --network none --entrypoint bash $img -s (selftest)"
                    printf '%s\n' "$script" >"${LOCK_DIR:-/tmp}/kmod-selftest.sh" 2>/dev/null \
                        && chmod 600 "${LOCK_DIR:-/tmp}/kmod-selftest.sh"
                    fx="${GOAMNEZIA_KMOD_SELFTEST_FIXTURE:-}"
                    if [ -n "$fx" ] && [ -f "$fx" ]; then
                        out=$(cat "$fx")
                    else
                        out=$(printf 'SELFTEST START\n'; sed -n 's/^gst_case \([^ ]*\) .*/CASE \1 OK ping=2/p' <<<"$script"; printf 'SELFTEST END\n')
                    fi
                else
                    out=$(printf '%s\n' "$script" | timeout 300 docker run --rm -i --privileged --network none \
                        --entrypoint bash "$img" -s 2>&1) || true
                fi
                if ! grep -q '^SELFTEST END' <<<"$out"; then
                    allok=false
                    reason=$(tf kmod_err_selftest_run "$(grep -v '^CASE\|^SELFTEST' <<<"$out" | tail -n 1 | cut -c1-160)")
                fi
            fi
        fi
    fi
    while read -r _ id ok detail; do
        [ -n "$id" ] || continue
        p="${id%[pk]}"
        case "$id" in *k) c=kernel ;; *) c=program ;; esac
        line=$(ga_profile_line "$p" 2>/dev/null)
        if [ "$ok" != OK ]; then
            allok=false
            [ -n "$reason" ] || reason=$(tf kmod_err_selftest_case "$p" "$line" "$(_ga_kmod_client_word "$c")" "${detail:-?}")
        fi
        js=$(jq -c --arg id "$id" --arg p "$p" --arg l "$line" --arg c "$c" --argjson ok "$([ "$ok" = OK ] && echo true || echo false)" \
            --arg d "${detail:-}" '. + [{id: $id, profile: $p, line: $l, client: $c, ok: $ok, detail: $d}]' <<<"$js")
    done < <(grep '^CASE ' <<<"$out")
    if [ "$allok" = true ] && [ -n "$script" ] && [ "$(jq 'length' <<<"$js")" = 0 ]; then
        allok=false; reason=$(tf kmod_err_selftest_run "-")
    fi
    out=$(jq -cn --argjson ok "$allok" --arg k "$k" --arg l "$label" --arg at "$(ga_now)" --argjson cases "$js" --arg r "$reason" \
        '{ok: $ok, kernel: $k, label: $l, at: $at, cases: $cases, reason: $r}')
    _ga_kmod_state_edit '.selftest = $s' --argjson s "$out"
    printf '%s' "$out"
    if [ "$allok" != true ]; then
        GA_ERR_CODE=kmod_selftest_failed; GA_ERR_MSG="$(tf kmod_err_selftest "$reason")"; ga_set_error kmod_selftest_failed
        log_error "$GA_ERR_MSG"
        return 1
    fi
    return 0
}
_ga_kmod_client_word() { case "$1" in kernel) t kmod_word_client_kernel ;; *) t kmod_word_client_program ;; esac; }
# Самопроверка этого ядра с этой меткой уже прошла?
_ga_kmod_selftest_fresh() {
    local s k l
    s=$(_ga_kmod_state | jq -c '.selftest // {}')
    k=$(ga_kmod_kernel); l=$(ga_kmod_loaded_version 2>/dev/null) || l=""
    [ "$(jq -r '.ok // false' <<<"$s")" = true ] && [ "$(jq -r '.kernel // ""' <<<"$s")" = "$k" ] \
        && [ "$(jq -r '.label // ""' <<<"$s")" = "$l" ]
}

# ── Установка (Б3–Б7) ────────────────────────────────────────────────────────
# ga_kmod_install <rebuild on|off> <headers_meta on|off> → JSON {state, version, kernel, owner, reused, p218,
# packages[], headers_meta_skipped, selftest, want, duration_s, reload, loaded, on_disk}. Движок профилей не меняет: до
# выбора человека (kmod-engine) все профили закреплены за программой файлом engine — модуль в памяти иначе подхватили бы
# при следующем рестарте. Провал на любом шаге оставляет профили на программе и пишет причину с ядром (failed).
# rebuild=on при модуле в памяти (KMODB-03) — новый модуль и в память: профили на модуле — через программу и обратно
# (_ga_kmod_reload_swap, reload=swapped), на модуле никого — выгрузка и загрузка (reloaded), модулем пользуется сосед
# Kaskad — только на диск (neighbour: новый загрузится при перезагрузке).
ga_kmod_install() {
    local rebuild="${1:-off}" meta="${2:-off}" k t0 check owner reused=false rc=0
    [ "$rebuild" = on ] || rebuild=off
    [ "$meta" = on ] || meta=off
    GA_KMOD_ACTION=install
    [ "$rebuild" = on ] && GA_KMOD_ACTION=rebuild
    # Шаг и начатый перевод — с нуля до первых проверок: иначе отказ «занято» после прошлой неудачной пересборки в той же
    # оболочке (SSH-меню) говорил бы о переводе, которого в этот раз не было (_ga_kmod_left_words).
    GA_KMOD_STEP=check; GA_KMOD_SWAP_STARTED=0; GA_KMOD_ROLLBACK_DOWN=""
    _ga_kmod_host_ok || return 2
    if _ga_kmod_busy; then ga_err kmod_busy "$(t kmod_err_busy)" 1; return 1; fi
    t0=$(_ga_kmod_now)
    k=$(ga_kmod_kernel)
    _ga_kmod_progress "$GA_KMOD_ACTION" check "$(tf kmod_step_check "$k")"
    check=$(ga_kmod_check_json)
    if [ "$(jq -r '.ok' <<<"$check")" != true ]; then
        ga_err kmod_unsupported "$(jq -r '.reason' <<<"$check")" 2
        _ga_kmod_progress_done
        return 2
    fi
    GA_KMOD_META_SKIPPED=""; GA_KMOD_P218=false; GA_KMOD_BUILD_LOG=""; GA_KMOD_STEP=check; GA_KMOD_RELOAD=""
    GA_KMOD_SWAP_STARTED=0
    _ga_kmod_install_steps "$k" "$rebuild" "$meta" || rc=$?
    if [ "$rc" != 0 ]; then
        _ga_kmod_fail "$k" "${GA_KMOD_STEP:-?}" "$(_ga_kmod_left_words state)"
        _ga_kmod_progress_done
        return "$rc"
    fi
    owner=$(ga_kmod_owner)
    [ "${GA_KMOD_REUSED:-0}" = 1 ] && reused=true
    _ga_kmod_state_edit '.installed = true | .owner = $o | .version = $v | .kernels = (((.kernels // []) + [$k]) | unique)
        | .p218 = $p | .at = $at | del(.failed) | del(.fallback) | del(.removed_at)' \
        --arg o "$owner" --arg v "$(ga_kmod_loaded_version)" --arg k "$k" --argjson p "${GA_KMOD_P218:-false}" --arg at "$(ga_now)"
    [ "$rebuild" = on ] && _ga_kmod_state_edit '.rebuild = {label: $l, kernel: $k, at: $at, ok: true}' \
        --arg l "$(ga_kmod_loaded_version)" --arg k "$k" --arg at "$(ga_now)"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "kmod-$GA_KMOD_ACTION" "done version=$(ga_kmod_loaded_version) kernel=$k owner=$owner${GA_KMOD_RELOAD:+ reload=$GA_KMOD_RELOAD}"
    # Итог словами — что теперь в памяти (KMODB-03): пересборка загружает новый модуль, а не только кладёт его на диск.
    case "${GA_KMOD_RELOAD:-}:$rebuild" in
        swapped:on)   log_success "$(tf kmod_rebuilt_swapped "$(ga_kmod_loaded_version)" "$k")" ;;
        reloaded:on)  log_success "$(tf kmod_rebuilt_reloaded "$(ga_kmod_loaded_version)" "$k")" ;;
        neighbour:on) log_warning "$(_ga_kmod_wrap "$(tf kmod_rebuilt_neighbour "$(ga_kmod_ko_version "$k")" "$k")")" ;;
        *)            log_success "$(tf kmod_installed "$(ga_kmod_loaded_version)" "$k")" ;;
    esac
    _ga_kmod_progress_done
    # reload — что стало с модулем в памяти: swapped (профили переведены через программу), reloaded (выгружен и загружен
    # заново), neighbour (им пользуется Kaskad — новый загрузится при перезагрузке), пусто — в памяти не было или
    # загружен впервые. loaded — метка модуля в памяти сейчас.
    jq -cn --arg st "$(_ga_kmod_status_field state)" --arg v "$(ga_kmod_loaded_version)" --arg k "$k" --arg o "$owner" \
        --argjson r "$reused" --argjson p "${GA_KMOD_P218:-false}" --argjson pk "$(_ga_kmod_state | jq -c '.pkgs // []')" \
        --arg ms "$GA_KMOD_META_SKIPPED" --argjson stt "$(_ga_kmod_state | jq -c '.selftest // null')" \
        --argjson d "$(( $(_ga_kmod_now) - t0 ))" --arg want "$(ga_kmod_want)" --arg rl "${GA_KMOD_RELOAD:-}" \
        --arg kv "$(ga_kmod_ko_version "$k" 2>/dev/null)" \
        '{state: $st, version: $v, kernel: $k, owner: $o, reused: $r, p218: $p, packages: $pk,
          headers_meta_skipped: $ms, selftest: $stt, want: $want, duration_s: $d, reload: $rl, loaded: $v,
          on_disk: $kv}'
}
_ga_kmod_install_steps() {
    local k="$1" rebuild="$2" meta="$3" kover lver
    GA_KMOD_REUSED=0
    kover=$(ga_kmod_ko_version "$k" 2>/dev/null) || kover=""
    lver=$(ga_kmod_loaded_version 2>/dev/null) || lver=""
    # Чужой модуль без набора под это ядро (и исходники не наши): не воюем — пусть уберут, или остаётся программа.
    if [ -n "$kover" ] && ! ga_kmod_label_ok "$kover" && ! _ga_kmod_ours_src && [ ! -d "$(ga_kmod_src_dir)" ]; then
        GA_KMOD_STEP=check
        ga_err kmod_foreign "$(tf kmod_err_foreign "$kover")" 1
        return 1
    fi
    # Сначала закрепить профили за выбранным движком (не выбирал — программа) — без перезапуска.
    GA_KMOD_STEP=pin
    ga_with_config_lock _ga_kmod_pin_all || return 1
    if ga_kmod_label_ok "$kover" && [ "$rebuild" != on ]; then
        # Модуль с меткой под это ядро уже стоит (сосед Kaskad или прошлая установка) — не пересобираем.
        GA_KMOD_REUSED=1
        _ga_kmod_progress "$GA_KMOD_ACTION" reuse "$(tf kmod_step_reuse "$kover")"
    else
        GA_KMOD_STEP="packages"; _ga_kmod_packages "$k" "$meta" || return 1
        GA_KMOD_STEP="source";   _ga_kmod_source || return 1
        GA_KMOD_STEP="patch";    _ga_kmod_patches "$k" || return 1
        GA_KMOD_STEP="build";    _ga_kmod_build "$k" || return 1
    fi
    GA_KMOD_STEP=load
    GA_KMOD_RELOAD=""
    if [ "$rebuild" = on ] && [ -n "$lver" ]; then
        # «Пересобрать» (KMODB-03): новый модуль — в память, как обещает экран, даже с той же меткой. Прежде он только
        # ложился на диск, в памяти оставался прежний до перезапуска сервера, а экран писал «собран и загружен».
        if ga_kmod_kaskad_uses; then
            # Модулем пользуется сосед Kaskad: выгрузить нельзя, не порвав его; новый загрузится при перезагрузке.
            GA_KMOD_RELOAD=neighbour
        elif [ -n "$(_ga_kmod_kernel_profiles)" ]; then
            # Профили на модуле: на время — программа (копия state/ и проверка людей, как у kmod-engine), выгрузка,
            # загрузка нового, самопроверка, обратно на модуль.
            ga_with_config_lock _ga_kmod_reload_swap "$k" || return 1
            GA_KMOD_RELOAD=swapped
        else
            _ga_kmod_reload "$k" || return 1
            GA_KMOD_RELOAD=reloaded
        fi
    elif [ -n "$lver" ] && [ "$lver" != "$(ga_kmod_ko_version "$k")" ] && [ -n "$(_ga_kmod_kernel_profiles)" ]; then
        # В памяти прежний модуль, и на нём профили: на время — программа, загрузка нового, обратно (рецепт §10).
        ga_with_config_lock _ga_kmod_reload_swap "$k" || return 1
        GA_KMOD_RELOAD=swapped
    else
        _ga_kmod_load "$k" || return 1
    fi
    GA_KMOD_STEP=hooks
    _ga_kmod_modload_install || { ga_err kmod_write_failed "$(tf kmod_err_write "$(_ga_kmod_modload_file)")"; return 1; }
    if _ga_kmod_ours_src; then
        _ga_kmod_hooks_install || { ga_err kmod_write_failed "$(tf kmod_err_write "$(_ga_kmod_etc)/kernel")"; return 1; }
        _ga_kmod_state_edit '.hooks = true'
    fi
    GA_KMOD_STEP=selftest
    # После перевода с пересборкой самопроверка нового модуля уже прошла — до возвращения профилей на модуль.
    [ "$GA_KMOD_RELOAD" = swapped ] && return 0
    ga_kmod_selftest >/dev/null || return 1
    return 0
}
# _ga_kmod_fail <ядро> <шаг> [где профили] — причина провала с ядром — в состояние; модуль, не прошедший самопроверку, из
# памяти выгружается (если на нём никого нет): непроверенный модуль подхватил бы любой новый контейнер. «Где профили»
# (_ga_kmod_left_words) — отдельно от самой ошибки, в .failed.left с загрузкой (.failed.boot) (R2-3, R4-1): служба
# пересборки после обновления отвечает только в журнал юнита, а kmod-status и шапка SSH показывают причину
# (_ga_kmod_failed_json) — без этих слов перевод на программу был бы молчаливым. Но слова верны только до следующей смены
# движка или перезагрузки: любой перевод (kmod-engine, удачный или с откатом) снимает .failed.left, а после
# перезагрузки их не показываем — остаётся сама ошибка.
_ga_kmod_fail() {
    local k="$1" step="$2" left="${3:-}"
    _ga_kmod_state_edit '.failed = {kernel: $k, step: $s, code: $c, reason: $r, left: $lw, boot: $b, log: $l, at: $at}' \
        --arg k "$k" --arg s "$step" --arg c "${GA_ERR_CODE:-failed}" --arg r "${GA_ERR_MSG:-}" --arg lw "$left" \
        --arg b "$(_ga_kmod_boot_id)" --arg l "${GA_KMOD_BUILD_LOG:-}" --arg at "$(ga_now)"
    if [ "$step" = selftest ] && [ -z "$(_ga_kmod_kernel_profiles)" ]; then
        modprobe -r amneziawg >/dev/null 2>&1 || true
    fi
    [ "${GA_KMOD_ACTION:-}" = rebuild ] && _ga_kmod_state_edit '.rebuild = {label: $l, kernel: $k, at: $at, ok: false}' \
        --arg l "$GA_KMOD_LABEL" --arg k "$k" --arg at "$(ga_now)"
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "kmod-${GA_KMOD_ACTION:-install}" "failed step=$step code=${GA_ERR_CODE:-failed} kernel=$k"
    return 0
}
# _ga_kmod_failed_json <ядро> → прошлый провал этого ядра для kmod-status ({kernel, step, code, reason, error, left, log,
# at}) или null. error — сама ошибка шага; left — «где профили и что выбрано» на момент сбоя, если с тех пор движок не
# переводили и сервер не перезагружали (иначе пусто, R4-1); reason — error и left одной строкой.
_ga_kmod_failed_json() {
    local k="$1" f err left
    f=$(_ga_kmod_state | jq -c --arg k "$k" 'if (.failed.kernel // "") == $k then .failed else null end' 2>/dev/null) || f=null
    [ -n "$f" ] && [ "$f" != null ] || { printf 'null'; return 0; }
    err=$(jq -r '.reason // ""' <<<"$f")
    left=$(jq -r --arg b "$(_ga_kmod_boot_id)" 'if (.boot // "") == $b then (.left // "") else "" end' <<<"$f")
    jq -c --arg e "$err" --arg lw "$left" --arg r "$(_ga_kmod_join_words "$err" "$left")" \
        '{kernel, step, code, reason: $r, error: $e, left: $lw, log, at}' <<<"$f"
}
# Профили, которые сейчас на модуле (живой опрос), через пробел.
_ga_kmod_kernel_profiles() {
    local p out=""
    for p in $(ga_kmod_profiles 2>/dev/null); do
        [ "$(ga_kmod_engine_now "$p" live)" = kernel ] && out+="$p "
    done
    printf '%s' "${out% }"
}
# _ga_kmod_pin_all — каждый профиль закреплён за выбранным движком (не выбирал — программа) файлом engine и блоком в
# start.sh; у кого файл уже есть — не трогаем. Без перезапуска.
_ga_kmod_pin_all() {
    local w p
    w=$(ga_kmod_want)
    if [ -z "$w" ]; then
        w=program
        _ga_kmod_state_edit '.want = "program"' || return 1
    fi
    for p in $(ga_kmod_profiles); do
        [ -n "$(ga_kmod_profile_want "$p")" ] && continue
        ga_kmod_engine_write "$p" "$w" || return 1
    done
    return 0
}
# _ga_kmod_reload_swap <ядро> — новый модуль вместо прежнего в памяти: профили на модуле — на программу, выгрузка,
# загрузка (и с той же меткой — пересборка, KMODB-03), самопроверка, профили обратно на модуль (два коротких обрыва).
# Оба перевода — ga_kmod_engine_set целиком: копия state/, по одному, проверка людей до 3 минут, откат при сбое. Под
# замком (ga_with_config_lock). Итог «Профили работают» переводы не печатают — его скажет пересборка.
_ga_kmod_reload_swap() {
    local k="$1" act="${GA_KMOD_ACTION:-rebuild}"
    GA_KMOD_SWAP_STARTED=1
    # Шаг — перевод на программу (проверяльщик 15.10, R2-4): его отказ — не «новый модуль не годится», модуль ещё не
    # трогали; load — только с выгрузки прежнего и загрузки нового.
    GA_KMOD_STEP=swap
    _ga_kmod_progress "$act" swap "$(t kmod_step_swap)"
    GA_KMOD_ENGINE_QUIET=1 _ga_kmod_engine_set_locked program >/dev/null || return 1
    GA_KMOD_ACTION="$act"
    GA_KMOD_STEP=load
    _ga_kmod_reload "$k" || return 1
    # Шаг — самопроверка: не прошла — непроверенный модуль выгружается (_ga_kmod_fail), профили остаются на программе.
    GA_KMOD_STEP=selftest
    ga_kmod_selftest >/dev/null || return 1
    GA_KMOD_STEP=switch
    GA_KMOD_ENGINE_QUIET=1 _ga_kmod_engine_set_locked kernel >/dev/null || return 1
    GA_KMOD_ACTION="$act"
    return 0
}
# _ga_kmod_left_words <ssh|bridge> → после неудачной установки или пересборки (код и шаг — в GA_ERR_CODE, GA_KMOD_STEP):
# где профили сейчас и что выбрано у сервера — по факту (KMODB-03, проверяльщик 15.10). На модуле в памяти — прежний
# модуль; перевод на программу начался (GA_KMOD_SWAP_STARTED) — профили на программе и выбор сервера, а если новый модуль
# не загрузился или не прошёл самопроверку — честно, что он не годится (включать его снова бесполезно); иначе — как
# вернуть их на модуль (SSH — пункт 1, мост и состояние — пункт меню по SSH). Провал на возвращении профилей (шаг switch,
# R2-2): новый модуль в памяти и прошёл самопроверку — так и сказано; люди не вернулись или движок не тот — повторять
# сразу бесполезно. Перевод не начинался — пусто: слова у вызывающего.
# Шаг hooks (R3-2): модуль уже загружен (после перевода — новый, профили снова на нём), не записались только файлы в /etc —
# «новый модуль не загружен» было бы неправдой. Откат не поднял профили (GA_KMOD_ROLLBACK_DOWN, R3-3) — не «пользователи
# переподключились», а какие профили не поднялись и что их надо проверить.
_ga_kmod_left_words() {
    local via="${1:-ssh}" want onk again down tail="" w
    onk=$(_ga_kmod_kernel_profiles)
    want=$(_ga_kmod_engine_word "$(ga_kmod_want)")
    down="${GA_KMOD_ROLLBACK_DOWN:-}"
    [ -n "$down" ] && tail=$(tf kmod_left_down "${down// /, }")
    if [ "${GA_KMOD_STEP:-}" = hooks ] && [ "${GA_KMOD_RELOAD:-}" != neighbour ]; then
        if [ "${GA_KMOD_RELOAD:-}" = swapped ]; then
            tf kmod_rebuild_left_hooks "$want"
        elif [ -n "$onk" ]; then
            tf kmod_left_hooks_kernel "${onk// /, }"
        fi
        return 0
    fi
    if [ -n "$onk" ]; then
        # На шаге switch прежний модуль уже выгружен: кто на модуле — на новом.
        if [ "${GA_KMOD_SWAP_STARTED:-0}" = 1 ] && [ "${GA_KMOD_STEP:-}" = switch ]; then
            w=$(tf kmod_rebuild_left_switch_kernel "${onk// /, }" "$want")
        else
            w=$(t kmod_rebuild_left_kernel)
        fi
        _ga_kmod_join_words "$w" "$tail"
        return 0
    fi
    [ "${GA_KMOD_SWAP_STARTED:-0}" = 1 ] || return 0
    if [ "$via" = ssh ]; then again=$(t kmod_rebuild_again_ssh); else again=$(t kmod_rebuild_again_bridge); fi
    case "${GA_KMOD_STEP:-}:${GA_ERR_CODE:-}" in
        *:kmod_in_use) ;;
        load:*|selftest:*) tf kmod_rebuild_left_bad "$want"; return 0 ;;
        switch:*)
            # Откат на программу не поднял профили — не «работают программой», а какие лежат.
            if [ -n "$down" ]; then tf kmod_rebuild_left_switch_down "${down// /, }" "$want"; return 0; fi
            case "${GA_ERR_CODE:-}" in
                kmod_clients_lost|kmod_engine_mismatch) tf kmod_rebuild_left_switch "$want" "$(t kmod_rebuild_switch_fix)" ;;
                *) tf kmod_rebuild_left_switch "$want" "$again" ;;
            esac
            return 0 ;;
        swap:*)
            # Перевод на программу не удался, а на модуле никого: откат на прежний модуль тоже не поднял профили (R3-3).
            [ -n "$tail" ] || tail=$(t kmod_left_check)
            _ga_kmod_join_words "$(tf kmod_rebuild_left_swap "$want")" "$tail"
            return 0 ;;
    esac
    tf kmod_rebuild_left_program "$want" "$again"
}
# _ga_kmod_join_words <слова шага> <где профили> — одной строкой: точка между ними, если у шага её нет.
_ga_kmod_join_words() {
    local a="$1" b="$2"
    [ -n "$b" ] || { printf '%s' "$a"; return 0; }
    [ -n "$a" ] || { printf '%s' "$b"; return 0; }
    case "$a" in *[.!?…]) printf '%s %s' "$a" "$b" ;; *) printf '%s. %s' "$a" "$b" ;; esac
}
# _ga_kmod_reload <ядро> — модуль с диска заново в память, даже с той же меткой: выгрузка (на нём кто-то есть —
# kmod_in_use) и загрузка с проверкой метки (_ga_kmod_load).
_ga_kmod_reload() {
    local k="$1" cur
    cur=$(ga_kmod_loaded_version 2>/dev/null) || cur=""
    if [ -n "$cur" ]; then
        _ga_kmod_progress "${GA_KMOD_ACTION:-rebuild}" unload "$(t kmod_step_unload)"
        if ! modprobe -r amneziawg >/dev/null 2>&1; then
            ga_err kmod_in_use "$(tf kmod_err_in_use "$cur")"
            return 1
        fi
    fi
    _ga_kmod_load "$k"
}

# ── Перевод движка (Б8, Б9) ──────────────────────────────────────────────────
# ga_kmod_ready → 0, если модуль можно включить: под нынешнее ядро он есть, в памяти с меткой набора, самопроверка
# этого ядра и этой метки прошла (не было — делается сейчас). Иначе код и слова в GA_ERR_CODE/GA_ERR_MSG.
ga_kmod_ready() {
    local k v
    k=$(ga_kmod_kernel)
    v=$(ga_kmod_loaded_version 2>/dev/null) || v=""
    if [ -z "$v" ]; then
        if ! ga_kmod_ko_file "$k" >/dev/null; then
            ga_err kmod_not_ready "$(tf kmod_why_no_module_kernel "$k")" 1
            return 1
        fi
        modprobe amneziawg >/dev/null 2>&1 || { ga_err kmod_load_failed "$(tf kmod_err_load "$k")"; return 1; }
        v=$(ga_kmod_loaded_version 2>/dev/null) || v=""
    fi
    if ! ga_kmod_label_ok "$v"; then
        ga_err kmod_not_ready "$(tf kmod_why_unpatched "${v:-?}")" 1
        return 1
    fi
    _ga_kmod_selftest_fresh && return 0
    ga_kmod_selftest >/dev/null || return 1
    return 0
}

# Стенд: «после перезапуска» контейнер отвечает фикстурами выбранного движка (.iplink.<движок>, .awgshow.<движок>).
_ga_kmod_dry_restarted() {
    local fs
    ga_dry || return 0
    fs=$(ga_docker_fs_path "$1" "") && [ -d "$fs" ] || return 0
    [ -f "$fs/.iplink.$2" ] && cp -f "$fs/.iplink.$2" "$fs/.iplink"
    [ -f "$fs/.awgshow.$2" ] && cp -f "$fs/.awgshow.$2" "$fs/.awgshow"
    return 0
}
# _ga_kmod_show <профиль> → пиры профиля JSON (amnezia_show); стенд — фикстура контейнера .awgshow.
_ga_kmod_show() {
    local c fs
    c=$(ga_profile_field "$1" container)
    if ga_dry && fs=$(ga_docker_fs_path "$c" ".awgshow") && [ -f "$fs" ]; then
        GOAMNEZIA_AWG_SHOW_FIXTURE="$fs" amnezia_show "$1" 2>/dev/null
        return $?
    fi
    amnezia_show "$1" 2>/dev/null
}
# _ga_kmod_alive <профиль> → открытые ключи тех, кто на связи: рукопожатие моложе 3 минут (по строке).
_ga_kmod_alive() {
    local js
    js=$(_ga_kmod_show "$1") || js='[]'
    jq -r --argjson now "$(_ga_kmod_now)" --argjson w "$GA_KMOD_ALIVE_WINDOW" \
        '.[]? | select((.latest_handshake_ts // 0) > 0 and ($now - .latest_handshake_ts) < $w) | .pubkey' <<<"$js" 2>/dev/null
}
# _ga_kmod_returned <профиль> <момент перезапуска> <ключи по строке> → «сколько вернулось:через сколько секунд первый»
# (-1 — никто). Вернулся — рукопожатие не раньше перезапуска: интерфейс новый, прежних рукопожатий у него нет.
_ga_kmod_returned() {
    local js
    js=$(_ga_kmod_show "$1") || js='[]'
    jq -r --argjson t "$2" --arg keys "$3" \
        '($keys | split("\n") | map(select(. != ""))) as $k
         | [.[]? | . as $x | select(($k | index($x.pubkey)) != null and ($x.latest_handshake_ts // 0) >= ($t - 2))
              | .latest_handshake_ts] as $hs
         | "\($hs | length):\(if ($hs | length) > 0 then (($hs | min) - $t | if . < 0 then 0 else . end) else -1 end)"' \
        <<<"$js" 2>/dev/null || printf '0:-1'
}

# ga_kmod_engine_set <kernel|program> → JSON {engine, want, profiles: [{profile, from, to, restarted, alive_before,
# returned, return_s, note}], rolled_back, copies}. По одному (awg2, awg1, awg3): копия state/, файл engine и блок
# в start.sh, перезапуск, проверка `ip -d link` (amneziawg | tun) и до 3 минут — вернётся ли хоть один из тех, кто был
# на связи. Не вернулся никто или движок не тот — откат всего сервера на прежний движок (kmod_clients_lost,
# kmod_engine_mismatch), в ответе — что было. Ключи людей не меняются: тот же awg0.conf, тот же порт.
ga_kmod_engine_set() { ga_with_config_lock _ga_kmod_engine_set_locked "$@"; }
_ga_kmod_engine_set_locked() {
    local target="${1:-}" prev_want p c st from alive t0 nowt res n s actual note copies rows='[]' rc=0 code="" msg=""
    local -a done_list=()
    # Профили, которые откат этого перевода не поднял (_ga_kmod_rollback) — для слов «где профили» (R3-3).
    GA_KMOD_ROLLBACK_DOWN=""
    case "$target" in kernel|program) ;; *) ga_err kmod_bad_engine "$(tf kmod_err_bad_engine "$target")" 2; return 2 ;; esac
    if _ga_kmod_busy; then ga_err kmod_busy "$(t kmod_err_busy)" 1; return 1; fi
    GA_KMOD_ACTION=engine
    if [ "$target" = kernel ]; then
        ga_kmod_ready || { _ga_kmod_progress_done; return 1; }
    fi
    prev_want=$(ga_kmod_want)
    # Перевод меняет, где профили и что выбрано: слова прошлого провала об этом (.failed.left) больше не правда (R4-1).
    _ga_kmod_state_edit '.want = $w | .want_at = $at | .want_by = $by | del(.failed.left)' --arg w "$target" --arg at "$(ga_now)" \
        --arg by "${GOAMNEZIA_WHO:-ssh}" || { ga_err kmod_write_failed "$(tf kmod_err_write "$(ga_kmod_state_file)")"; return 1; }
    copies=$(_ga_kmod_copy_state)
    for p in $(ga_kmod_profiles); do
        c=$(ga_profile_field "$p" container)
        ga_capture st docker_container_state "$c"
        from=""; [ "$st" = running ] && from=$(ga_kmod_engine_now "$p" live)
        if ! ga_kmod_engine_write "$p" "$target"; then
            code="${GA_ERR_CODE:-kmod_write_failed}"; msg="${GA_ERR_MSG:-}"; rc=1; break
        fi
        if [ "$st" != running ]; then
            rows=$(jq -c --arg p "$p" --arg t "$target" --arg st "$st" '. + [{profile: $p, from: "", to: $t, restarted: false,
                alive_before: 0, returned: 0, return_s: null, note: ("not_running:" + $st)}]' <<<"$rows")
            log_info "$(_ga_kmod_row_text "$(jq -c '.[-1]' <<<"$rows")")"
            continue
        fi
        if [ "$from" = "$target" ]; then
            rows=$(jq -c --arg p "$p" --arg t "$target" '. + [{profile: $p, from: $t, to: $t, restarted: false,
                alive_before: 0, returned: 0, return_s: null, note: "already"}]' <<<"$rows")
            log_info "$(_ga_kmod_row_text "$(jq -c '.[-1]' <<<"$rows")")"
            continue
        fi
        alive=$(_ga_kmod_alive "$p")
        n=$(grep -c . <<<"$alive")
        _ga_kmod_progress engine "restart:$p" "$(tf kmod_step_switch "$p" "$(_ga_kmod_engine_word "$target")")"
        t0=$(_ga_kmod_now)
        done_list+=("$p|$from")
        if ! docker_restart "$c" || ! ga_amn_wait_up "$p"; then
            code="${GA_ERR_CODE:-restart_failed}"; msg=$(tf kmod_err_restart "$p"); rc=1; break
        fi
        _ga_kmod_dry_restarted "$c" "$target"
        actual=$(ga_amn_engine "$p")
        _ga_kmod_engines_put "$p" "$actual"
        if [ "$actual" != "$target" ]; then
            code=kmod_engine_mismatch
            msg=$(tf kmod_err_mismatch "$p" "$(_ga_kmod_engine_word "$target")" "$(_ga_kmod_engine_word "$actual")")
            rc=1; break
        fi
        res="0:-1"
        if [ "$n" -gt 0 ]; then
            _ga_kmod_progress engine "wait:$p" "$(tf kmod_step_wait "$p" "$n")"
            while :; do
                res=$(_ga_kmod_returned "$p" "$t0" "$alive")
                [ "${res%%:*}" -gt 0 ] 2>/dev/null && break
                nowt=$(_ga_kmod_now)
                [ $((nowt - t0)) -ge "$GA_KMOD_WAIT_CLIENTS" ] && break
                _ga_kmod_sleep "$GA_KMOD_POLL"
            done
            if ! [ "${res%%:*}" -gt 0 ] 2>/dev/null; then
                code=kmod_clients_lost; msg=$(tf kmod_err_clients_lost "$p" "$n" "$((GA_KMOD_WAIT_CLIENTS / 60))"); rc=1
                rows=$(jq -c --arg p "$p" --arg f "$from" --arg t "$actual" --argjson a "$n" \
                    '. + [{profile: $p, from: $f, to: $t, restarted: true, alive_before: $a, returned: 0, return_s: null,
                      note: "lost"}]' <<<"$rows")
                break
            fi
        fi
        s="${res#*:}"; [ "$s" = -1 ] && s=null
        note=""; [ "$n" -gt 0 ] || note="no_clients"
        rows=$(jq -c --arg p "$p" --arg f "$from" --arg t "$actual" --argjson a "$n" --argjson r "${res%%:*}" \
            --argjson s "$s" --arg nt "$note" \
            '. + [{profile: $p, from: $f, to: $t, restarted: true, alive_before: $a, returned: $r, return_s: $s, note: $nt}]' <<<"$rows")
        log_success "$(_ga_kmod_row_text "$(jq -c '.[-1]' <<<"$rows")")"
        amnezia_state_sync "$p" >/dev/null 2>&1 || true
    done
    if [ "$rc" != 0 ]; then
        _ga_kmod_rollback "$target" "$prev_want" "${done_list[@]+"${done_list[@]}"}"
        GA_ERR_CODE="$code"; GA_ERR_MSG="$msg"; ga_set_error "$code"
        log_error "$msg"
        ga_audit "${GOAMNEZIA_WHO:-ssh}" "kmod-engine" "rolled_back to=$target code=$code"
        _ga_kmod_progress_done
        jq -cn --arg e "$target" --arg w "$(ga_kmod_want)" --argjson rows "$rows" --arg cp "$copies" \
            '{engine: $e, want: $w, profiles: $rows, rolled_back: true, copies: $cp}'
        return 1
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "kmod-engine" "to=$target profiles=$(jq -r 'map(.profile) | join(",")' <<<"$rows")"
    # Перевод на модуль прошёл: модуль этого ядра с меткой набора в памяти, самопроверка свежая, запущенные профили на
    # модуле (у кого были пользователи — они вернулись; у профилей без пользователей (no_clients) и не запущенных
    # (not_running) возврат не проверялся — не запущенные перейдут при старте). Провал
    # этого ядра на загрузке, самопроверке или переводе профилей (load, selftest, swap, switch) этим опровергнут — снят
    # (R3-1). Провал до них (пакеты, исходники, патч, сборка — с журналом failed.log) и файлов в /etc (hooks) остаётся
    # правдой: снимет его удачная установка (R4-2); «где профили» у него уже снято выше.
    if [ "$target" = kernel ]; then
        _ga_kmod_state_edit 'if (.failed.kernel // "") == $k and ((.failed.step // "") as $s | ["load", "selftest", "swap", "switch"] | any(. == $s))
            then del(.failed) else . end' --arg k "$(ga_kmod_kernel)" || true
    fi
    # Итог — одной строкой здесь, и больше нигде (KMODB-02: экран печатал его второй раз). GA_KMOD_ENGINE_QUIET=1 —
    # перевод шагом пересборки (_ga_kmod_reload_swap): её итог скажет сама пересборка.
    [ "${GA_KMOD_ENGINE_QUIET:-0}" = 1 ] || log_success "$(tf kmod_engine_done "$(_ga_kmod_engine_word "$target")")"
    _ga_kmod_progress_done
    jq -cn --arg e "$target" --arg w "$(ga_kmod_want)" --argjson rows "$rows" --arg cp "$copies" \
        '{engine: $e, want: $w, profiles: $rows, rolled_back: false, copies: $cp}'
}
# _ga_kmod_rollback <движок, на который шли> <прежний выбор> <профиль|прежний движок>… — в обратном порядке прежний
# движок (не узнан — противоположный тому, на который шли), перезапуск и подъём; людей не ждём. Выбор сервера —
# прежний (не выбирал — программа).
_ga_kmod_rollback() {
    local target="$1" prev_want="$2" i e p from back c
    shift 2
    local -a list=("$@")
    log_warning "$(tf kmod_rollback "$(_ga_kmod_engine_word "$target")")"
    for ((i = ${#list[@]} - 1; i >= 0; i--)); do
        e="${list[$i]}"; p="${e%%|*}"; from="${e#*|}"
        case "$from" in kernel|program) back="$from" ;; *) back="" ;; esac
        if [ -z "$back" ] || [ "$back" = "$target" ]; then
            if [ "$target" = kernel ]; then back=program; else back=kernel; fi
        fi
        c=$(ga_profile_field "$p" container)
        ga_kmod_engine_write "$p" "$back" >/dev/null || true
        if docker_restart "$c" >/dev/null && ga_amn_wait_up "$p" >/dev/null; then
            _ga_kmod_dry_restarted "$c" "$back"
            _ga_kmod_engines_put "$p" "$(ga_amn_engine "$p")"
            log_info "$(tf kmod_rolled_back "$p" "$(_ga_kmod_engine_word "$back")")"
        else
            log_error "$(tf kmod_err_restart "$p")"
            GA_KMOD_ROLLBACK_DOWN="${GA_KMOD_ROLLBACK_DOWN:+$GA_KMOD_ROLLBACK_DOWN }$p"
        fi
        amnezia_state_sync "$p" >/dev/null 2>&1 || true
    done
    [ -n "$prev_want" ] || prev_want=program
    _ga_kmod_state_edit '.want = $w' --arg w "$prev_want" >/dev/null 2>&1 || true
    return 0
}
# _ga_kmod_copy_state → путь копии state/ профилей перед переводом (0700/0600); хранятся три последние.
_ga_kmod_copy_state() {
    local root dir p c old
    root=$(_ga_kmod_copies_dir)
    { mkdir -p "$root" && chmod 700 "$root"; } 2>/dev/null || { printf ''; return 0; }
    dir=$(mktemp -d "$root/$(date -u +%Y%m%d-%H%M%S)-XXXXXX" 2>/dev/null) || { printf ''; return 0; }
    chmod 700 "$dir"
    for p in $(ga_kmod_profiles); do
        c=$(ga_profile_field "$p" container)
        [ "$(docker_container_state "$c" 2>/dev/null)" = running ] && amnezia_state_sync "$p" >/dev/null 2>&1
        [ -d "$STATE_DIR/$c" ] && cp -a "$STATE_DIR/$c" "$dir/" 2>/dev/null
    done
    find "$dir" -type d -exec chmod 700 {} + 2>/dev/null
    find "$dir" -type f -exec chmod 600 {} + 2>/dev/null
    while IFS= read -r old; do
        [ -n "$old" ] && rm -rf "$old"
    done < <(find "$root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort | awk -v keep="$GA_KMOD_COPIES_KEEP" \
        '{ a[NR] = $0 } END { for (i = 1; i <= NR - keep; i++) print a[i] }')
    printf '%s' "$dir"
}
_ga_kmod_engine_word() {
    case "$1" in
        kernel)  t kmod_word_kernel ;;
        program) t kmod_word_program ;;
        stopped) t kmod_word_stopped ;;
        *)       t kmod_word_unknown ;;
    esac
}
# _ga_kmod_row_text <строка profiles[] ответа kmod-engine> → одна строка словами.
_ga_kmod_row_text() {
    local r="$1" p to a n s note
    p=$(jq -r '.profile' <<<"$r"); to=$(jq -r '.to' <<<"$r"); a=$(jq -r '.alive_before' <<<"$r")
    n=$(jq -r '.returned' <<<"$r"); s=$(jq -r '.return_s // "?"' <<<"$r"); note=$(jq -r '.note // ""' <<<"$r")
    case "$note" in
        already)      tf kmod_row_already "$p" "$(_ga_kmod_engine_word "$to")" ;;
        not_running*) tf kmod_row_not_running "$p" "$(_ga_kmod_engine_word "$to")" ;;
        no_clients)   tf kmod_row_no_clients "$p" "$(_ga_kmod_engine_word "$to")" ;;
        lost)         tf kmod_row_lost "$p" "$a" ;;
        *)            tf kmod_row_back "$p" "$(_ga_kmod_engine_word "$to")" "$n" "$a" "$s" ;;
    esac
}

# ── Удаление (Б14, рецепт §11) ───────────────────────────────────────────────
# ga_kmod_remove [wipe] → JSON {removed, kept_for_neighbour, packages[], command}. Порядок важен: профили на программу
# («Удалить всё» — контейнеров уже нет), modprobe -r, dkms remove --all, исходники, хуки, modules-load; пакеты, которые
# ставили мы, — называем строкой apt remove, сами не удаляем. Модулем пользуется сосед Kaskad — модуль, DKMS и исходники
# не трогаем, убираем только своё (хуки, отметку, modules-load, если его ставили мы).
ga_kmod_remove() {
    local mode="${1:-}" kept=false removed=false pkgs cmd f src
    GA_KMOD_ACTION=remove
    _ga_kmod_host_ok || return 2
    if _ga_kmod_busy; then ga_err kmod_busy "$(t kmod_err_busy)" 1; return 1; fi
    if [ "$mode" != wipe ] && [ -n "$(ga_kmod_profiles 2>/dev/null)" ]; then
        _ga_kmod_progress remove program "$(t kmod_step_remove_program)"
        ga_kmod_engine_set program >/dev/null || { _ga_kmod_progress_done; return 1; }
        GA_KMOD_ACTION=remove
    fi
    if ga_kmod_kaskad_uses; then
        kept=true
        _ga_kmod_progress remove neighbour "$(t kmod_step_remove_neighbour)"
    elif _ga_kmod_ours_src || [ "$(_ga_kmod_state_get '.installed')" = true ]; then
        if ga_kmod_loaded_version >/dev/null; then
            _ga_kmod_progress remove unload "$(t kmod_step_unload)"
            if ! modprobe -r amneziawg >/dev/null 2>&1; then
                ga_err kmod_in_use "$(tf kmod_err_in_use "$(ga_kmod_loaded_version)")"
                _ga_kmod_progress_done
                return 1
            fi
        fi
        if _ga_kmod_ours_src; then
            _ga_kmod_progress remove dkms "$(t kmod_step_dkms_remove)"
            dkms remove -m amneziawg -v "$GA_KMOD_VER" --all >/dev/null 2>&1 || true
            src=$(ga_kmod_src_dir)
            case "$src" in */amneziawg-"$GA_KMOD_VER") rm -rf "$src" ;; esac
        fi
        removed=true
    fi
    # Своё — всегда: хуки, modules-load (если ставили мы и модуль не остаётся соседу), отметку.
    while IFS= read -r f; do [ -n "$f" ] && rm -f "$f"; done < <(_ga_kmod_hook_paths)
    local ml_gone=false
    if [ "$(_ga_kmod_state_get '.modules_load')" = true ] && [ "$kept" = false ]; then
        rm -f "$(_ga_kmod_modload_file)" && ml_gone=true
    fi
    rm -f "$(ga_kmod_src_dir)/.goamnezia" 2>/dev/null
    pkgs=$(_ga_kmod_state | jq -c '[.pkgs // [] | .[] | select(type == "string")]')
    cmd=""
    [ "$(jq 'length' <<<"$pkgs")" -gt 0 ] && cmd="apt remove $(jq -r 'join(" ")' <<<"$pkgs")"
    if [ "$mode" != wipe ]; then
        # modules-load, оставленный соседу, всё ещё наш: следующее удаление (соседа уже нет) его уберёт.
        _ga_kmod_state_edit '.installed = false | .want = "program" | .hooks = false
            | .modules_load = (if $mg then false else (.modules_load // false) end)
            | .removed_at = $at | del(.selftest) | del(.failed) | del(.fallback)' --arg at "$(ga_now)" --argjson mg "$ml_gone"
    fi
    ga_audit "${GOAMNEZIA_WHO:-ssh}" "kmod-remove" "removed=$removed kept_for_neighbour=$kept"
    _ga_kmod_progress_done
    [ -n "$cmd" ] && log_info "$(tf kmod_remove_packages "$cmd")"
    jq -cn --argjson r "$removed" --argjson k "$kept" --argjson p "$pkgs" --arg c "$cmd" \
        '{removed: $r, kept_for_neighbour: $k, packages: $p, command: $c}'
}

# ── Видимость: status.kmod, карточка профиля, шапка меню (Б10) ────────────────
# ga_kmod_status_json → {loaded, version, patched, warn (этап А, как прежде), state, code, reason, kernel, want,
# installed, installed_version, owner, label, profiles: {awg2: {engine, want}}, progress, selftest, failed, packages}.
# state: off — модуля нет (по умолчанию: программа) | ready — модуль готов, профили на программе | on — профили на
# модуле | fallback — выбран модуль, а профили на программе (нет модуля под это ядро, не загружен) | failed — последняя
# установка на этом ядре не удалась | unpatched — в памяти чужой модуль без набора | busy — идёт установка или перевод.
# reason — словами и с ядром. Дёшево: /sys, файлы состояния, кэш движков (в Docker — раз в 10 минут, если модуль в памяти).
ga_kmod_status_json() {
    local base k lver="" patched=false loaded=false inst=false kover="" owner want prog st code="" reason="" failed=null
    local p eng pw engines='{}' onprog="" sel=null pk rm_at
    base=$(ga_amn_kmod_json 2>/dev/null) || base=""
    [ -n "$base" ] || base='{"loaded":false,"version":"","patched":false,"warn":false}'
    k=$(ga_kmod_kernel)
    lver=$(ga_kmod_loaded_version 2>/dev/null) && loaded=true
    ga_kmod_label_ok "$lver" && patched=true
    if ga_kmod_ko_file "$k" >/dev/null; then inst=true; kover=$(ga_kmod_ko_version "$k" 2>/dev/null) || kover=""; fi
    owner=$(ga_kmod_owner)
    want=$(ga_kmod_want)
    prog=$(ga_kmod_progress_json)
    if [ -f "$(ga_kmod_state_file)" ] || [ "$loaded" = true ]; then
        for p in $(ga_kmod_profiles 2>/dev/null); do
            eng=$(ga_kmod_engine_now "$p")
            pw=$(ga_kmod_profile_want "$p")
            engines=$(jq -c --arg p "$p" --arg e "$eng" --arg w "$pw" '. + {($p): {engine: $e, want: $w}}' <<<"$engines")
            [ "$eng" = program ] && onprog+="$p "
        done
    fi
    onprog="${onprog% }"
    failed=$(_ga_kmod_failed_json "$k")
    if [ "$prog" != null ]; then
        st=busy; code=$(jq -r '.action // ""' <<<"$prog")
    elif [ "$want" = kernel ]; then
        if [ "$loaded" = true ] && [ "$patched" = true ] && [ -z "$onprog" ]; then
            st=on
        else
            st=fallback
            if [ "$loaded" != true ] && [ "$inst" != true ]; then
                code=no_module_for_kernel; reason=$(tf kmod_why_fallback_no_module "$k")
            elif [ "$loaded" = true ] && [ "$patched" != true ]; then
                code=unpatched; reason=$(tf kmod_why_fallback_unpatched "$lver")
            elif [ "$loaded" != true ]; then
                code=not_loaded; reason=$(tf kmod_why_fallback_not_loaded "$k")
            else
                code=profiles_on_program; reason=$(tf kmod_why_fallback_profiles "$onprog")
            fi
        fi
    elif [ "$failed" != null ]; then
        st=failed; code=$(jq -r '.code // "failed"' <<<"$failed"); reason=$(jq -r '.reason // ""' <<<"$failed")
    elif [ "$loaded" = true ] && [ "$patched" != true ]; then
        st=unpatched; code=unpatched; reason=$(tf kmod_why_unpatched "$lver")
    elif { [ "$loaded" = true ] && [ "$patched" = true ]; } || ga_kmod_label_ok "$kover"; then
        st=ready
    else
        st=off
    fi
    sel=$(_ga_kmod_state | jq -c '.selftest // null | if . == null then null else {ok, kernel, label, at, reason} end')
    pk=$(_ga_kmod_state | jq -c '[.pkgs // [] | .[] | select(type == "string")]')
    # removed_at — когда модуль удалили пунктом «Удалить модуль» (kmod-remove), если он с тех пор не ставился: состояние
    # off у него — «удалён», а не «не ставился» (KMODB-01). Установка это поле снимает.
    rm_at=$(_ga_kmod_state | jq -c 'if (.installed // false) != true and ((.removed_at // "") | type) == "string"
        and (.removed_at // "") != "" then .removed_at else null end' 2>/dev/null) || rm_at=null
    [ -n "$rm_at" ] || rm_at=null
    jq -c --arg st "$st" --arg code "$code" --arg reason "$reason" --arg k "$k" --arg w "$want" --argjson inst "$inst" \
        --arg kv "$kover" --arg o "$owner" --arg l "$GA_KMOD_LABEL" --argjson e "$engines" --argjson pr "$prog" \
        --argjson sel "$sel" --argjson f "$failed" --argjson pk "$pk" --argjson rm "$rm_at" \
        '. + {state: $st, code: $code, reason: $reason, kernel: $k, want: $w, installed: $inst, installed_version: $kv,
              owner: $o, label: $l, profiles: $e, progress: $pr, selftest: $sel, failed: $f, packages: $pk,
              removed_at: $rm}' <<<"$base"
}
_ga_kmod_status_field() { ga_kmod_status_json | jq -r --arg f "$1" '.[$f] // ""' 2>/dev/null; }

# ga_kmod_card_line <профиль> — строка «Движок» карточки профиля SSH: фактический и, если выбран другой, — когда сменится.
ga_kmod_card_line() {
    local p="$1" eng want
    [ "$(ga_amn_iface "$p")" = awg0 ] || return 0
    eng=$(ga_kmod_engine_now "$p" live)
    want=$(ga_kmod_profile_want "$p")
    echo -e "  $(t kmod_card_engine): ${CYAN}$(_ga_kmod_engine_word "$eng")${NC}"
    if [ -n "$want" ] && [ "$eng" != "$want" ] && [ "$eng" != stopped ]; then
        log_warning "$(tf kmod_card_pending "$(_ga_kmod_engine_word "$want")")"
    fi
    return 0
}
# ga_kmod_dash_warn — строка в шапке главного меню: выбран модуль, а профили на программе (с ядром), или последняя
# установка не удалась. Модуль без набора (этап А) говорит _dash_kmod_warn сам.
ga_kmod_dash_warn() {
    local js st
    [ -f "$(ga_kmod_state_file)" ] || return 0
    js=$(ga_kmod_status_json)
    st=$(jq -r '.state' <<<"$js")
    case "$st" in
        fallback) log_warning "$(_ga_kmod_wrap "$(tf kmod_dash_fallback "$(jq -r '.reason' <<<"$js")")")" ;;
        failed)   log_warning "$(_ga_kmod_wrap "$(tf kmod_dash_failed "$(jq -r '.reason' <<<"$js")")")" ;;
    esac
    return 0
}
_ga_kmod_wrap() { if type _ui_w >/dev/null 2>&1; then _ui_w "$1"; else printf '%s' "$1"; fi; }

# ── Сторож (Б10, Б13): раз в 2 минуты из watch-tick ───────────────────────────
# ga_kmod_watch → JSON {want, kernel, state, seeded[], fallback, drift[], rebuild} или null (модулем не занимались).
#   • профили без файла engine (новый, подхваченный, восстановленный) — закрепить за выбранным, без перезапуска;
#   • выбран модуль, а после загрузки профили на программе (нет модуля под это ядро) — предупреждение словами с ядром,
#     в журнал и журнал действий — один раз на загрузку и ядро;
#   • выбрана программа, а профиль на модуле — перейдёт при следующем перезапуске (файл уже на месте), строкой один раз;
#   • модуль наш, а метка в памяти не та, что у этой версии (обновление goAmnezia) — пересборка отдельной службой
#     (kmod-install --rebuild=on), обновление её не ждёт; не собралось на этом ядре — сам не повторяет.
ga_kmod_watch() {
    local want k boot js st reason seeded=() drift=() p eng rebuild="" lver
    [ -f "$(ga_kmod_state_file)" ] || { printf 'null'; return 0; }
    want=$(ga_kmod_want)
    [ -n "$want" ] || { printf 'null'; return 0; }
    _ga_kmod_busy && { printf 'null'; return 0; }
    k=$(ga_kmod_kernel); boot=$(_ga_kmod_boot_id)
    for p in $(ga_kmod_profiles 2>/dev/null); do
        if [ -z "$(ga_kmod_profile_want "$p")" ]; then
            ga_kmod_engine_write "$p" "$want" >/dev/null 2>&1 && seeded+=("$p")
        fi
        eng=$(ga_kmod_engine_now "$p")
        [ "$want" = program ] && [ "$eng" = kernel ] && drift+=("$p")
    done
    js=$(ga_kmod_status_json)
    st=$(jq -r '.state' <<<"$js"); reason=$(jq -r '.reason' <<<"$js")
    if [ "$st" = fallback ]; then
        if [ "$(_ga_kmod_state_get '.fallback.boot')" != "$boot" ] || [ "$(_ga_kmod_state_get '.fallback.kernel')" != "$k" ]; then
            log_warning "$(tf kmod_watch_fallback "$reason")"
            ga_audit "watch" "kmod_fallback" "kernel=$k code=$(jq -r '.code' <<<"$js")"
            _ga_kmod_state_edit '.fallback = {kernel: $k, reason: $r, code: $c, boot: $b, at: $at}' --arg k "$k" \
                --arg r "$reason" --arg c "$(jq -r '.code' <<<"$js")" --arg b "$boot" --arg at "$(ga_now)"
        fi
    elif [ -n "$(_ga_kmod_state_get '.fallback.kernel')" ]; then
        _ga_kmod_state_edit 'del(.fallback)'
    fi
    if [ "${#drift[@]}" -gt 0 ] && [ "$(_ga_kmod_state_get '.drift_boot')" != "$boot" ]; then
        log_warning "$(tf kmod_watch_drift "${drift[*]}")"
        _ga_kmod_state_edit '.drift_boot = $b' --arg b "$boot"
    fi
    # Пересборка после обновления goAmnezia: модуль наш, а метка под это ядро — не нынешнего набора.
    lver=$(ga_kmod_ko_version "$k" 2>/dev/null) || lver=""
    if [ "$(_ga_kmod_state_get '.owner')" = goamnezia ] && _ga_kmod_ours_src && [ -n "$lver" ] \
       && [ "$lver" != "$GA_KMOD_LABEL" ] && ga_kmod_label_ok "$lver" \
       && ! { [ "$(_ga_kmod_state_get '.rebuild.kernel')" = "$k" ] && [ "$(_ga_kmod_state_get '.rebuild.label')" = "$GA_KMOD_LABEL" ] \
              && [ "$(_ga_kmod_state_get '.rebuild.ok')" = false ]; }; then
        _ga_kmod_rebuild_start && rebuild=started
    fi
    jq -cn --arg w "$want" --arg k "$k" --arg st "$st" --arg s "${seeded[*]+"${seeded[*]}"}" --arg d "${drift[*]+"${drift[*]}"}" \
        --arg r "$rebuild" '{want: $w, kernel: $k, state: $st, seeded: ($s | split(" ") | map(select(. != ""))),
          fallback: ($st == "fallback"), drift: ($d | split(" ") | map(select(. != ""))), rebuild: $r}'
}
# _ga_kmod_rebuild_start — отдельная служба (systemd-run): мост kmod-install --rebuild=on от имени таймера (ждёт общий
# замок до часа, а не 30 с). Повторно, пока служба жива, не запускается.
_ga_kmod_rebuild_start() {
    local unit="goamnezia-kmod-rebuild" bin
    bin="${GOAMNEZIA_DIR:-/opt/goamnezia}/install.sh"
    if ga_dry; then ga_dry_echo "systemd-run --unit=$unit --collect /bin/bash $bin --action=kmod-install --rebuild=on --json"; return 0; fi
    command -v systemd-run >/dev/null 2>&1 || return 1
    systemctl is-active --quiet "$unit" 2>/dev/null && return 1
    systemd-run --quiet --collect --unit="$unit" --setenv=GOAMNEZIA_WHO=timer --setenv=GOAMNEZIA_TIMER_LOCK_WAIT=3600 \
        /bin/bash "$bin" --action=kmod-install --rebuild=on --json >/dev/null 2>&1 || return 1
    ga_audit "watch" "kmod_rebuild_started" "label=$GA_KMOD_LABEL kernel=$(ga_kmod_kernel)"
    log_info "$(t kmod_rebuild_started)"
    return 0
}
# ga_kmod_after_update — шаг миграции при обновлении goAmnezia: хуки нового ядра — текстом этой версии (если модуль
# наш), профили без файла engine — закрепить за выбранным. Движок молча не меняет; пересборку под новую метку начнёт
# сторож отдельной службой (обновление её не ждёт).
ga_kmod_after_update() {
    local want p
    [ -f "$(ga_kmod_state_file)" ] || return 0
    if [ "$(_ga_kmod_state_get '.installed')" = true ] && _ga_kmod_ours_src && _ga_kmod_host_paths_ok; then
        _ga_kmod_hooks_install >/dev/null 2>&1 || true
    fi
    want=$(ga_kmod_want)
    [ -n "$want" ] || return 0
    for p in $(ga_kmod_profiles 2>/dev/null); do
        [ -n "$(ga_kmod_profile_want "$p")" ] && continue
        ga_kmod_engine_write "$p" "$want" >/dev/null 2>&1 || true
    done
    return 0
}

# ── Мост: kmod-status, kmod-check, kmod-install, kmod-engine, kmod-remove (Б12) ─
# ga_kmod_bridge <действие> — ветка диспетчера install.sh (_action_dispatch_locked зовёт её одной строкой). Ответ —
# JSON последней строкой (CONTRACT §0): чтения — полем kmod / check, изменения — итогом модуля в корне.
ga_kmod_bridge() {
    local name="$1" out="" js rb hm
    case "$name" in
        kmod-status)
            js=$(ga_kmod_status_json)
            ga_emit_json success "$(t act_ok)" "kmod=@json:$(_as_json "$js" null)"
            ;;
        kmod-check)
            js=$(ga_kmod_check_json plan)
            ga_emit_json success "$(t act_ok)" "check=@json:$(_as_json "$js" null)"
            ;;
        kmod-install)
            rb=$(_arg rebuild); hm=$(_arg headers_meta)
            GA_KMOD_APT_WAIT="${GA_KMOD_APT_WAIT:-600}"
            GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
            if ! ga_capture out ga_kmod_install "${rb:-off}" "${hm:-off}"; then
                # Пересборка с модулем в памяти могла успеть перевести профили на программу (KMODB-03): где они и что
                # выбрано у сервера — словами в message и полями engine (на чём профили сейчас) и want.
                local left eng=program
                left=$(_ga_kmod_left_words bridge)
                [ -n "$(_ga_kmod_kernel_profiles)" ] && eng=kernel
                ga_emit_json error "$(_ga_kmod_join_words "${GA_ERR_MSG:-$(t act_failed)}" "$left")" \
                    "code=${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-kmod_failed}}" "engine=$eng" "want=$(ga_kmod_want)" \
                    "swap_started=@json:$([ "${GA_KMOD_SWAP_STARTED:-0}" = 1 ] && echo true || echo false)"
                return 1
            fi
            _action_emit_merged success "$(t kmod_act_installed)" "$out"
            ;;
        kmod-engine)
            GA_ERR_CODE=""; GA_ERR_MSG=""; GA_LAST_ERROR_CODE=""
            if ga_capture out ga_kmod_engine_set "$(_arg engine)"; then
                _action_emit_merged success "$(t kmod_act_engine)" "$out"
            else
                # Откат — с тем, что успело случиться (profiles[], rolled_back), как у docker-restart: в корне ответа.
                js=$(_as_json "$out" '{}')
                js=$(jq -c --arg c "${GA_ERR_CODE:-${GA_LAST_ERROR_CODE:-kmod_failed}}" '. + {code: $c}' <<<"$js" 2>/dev/null) \
                    || js="{\"code\":\"kmod_failed\"}"
                _action_emit_merged error "${GA_ERR_MSG:-$(t act_failed)}" "$js"
                return 1
            fi
            ;;
        kmod-remove)
            _action_run kmod_failed ga_kmod_remove || return 1
            _action_emit_merged success "$(t kmod_act_removed)" "$out"
            ;;
        *)
            ga_emit_json error "$(tf act_unknown "$name")" "code=unknown_action"
            return 2
            ;;
    esac
}

# ── SSH-меню: «Обслуживание → Ускорение AmneziaWG (модуль ядра)» (Б11) ───────
# Пункты всегда те же (номера не скачут): 1 Включить, 2 Вернуть программу, 3 Пересобрать, 4 Удалить. Неприменимый
# пункт объясняет словами, почему сейчас нечего делать.
ga_kmod_screen() {
    local ch
    while true; do
        _screen_head "$(t kmod_title)" "$(t kmod_note)"
        _ga_kmod_screen_state
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -e "  ${CYAN}1${NC}) $(t kmod_item_enable)"
        echo -e "  ${CYAN}2${NC}) $(t kmod_item_program)"
        echo -e "  ${CYAN}3${NC}) $(t kmod_item_rebuild)"
        echo -e "  ${CYAN}4${NC}) ${RED}$(t kmod_item_remove)${NC}"
        echo -e "  ${CYAN}0${NC}) $(t back)"
        echo -e "  ${DIM}$(_rule)${NC}"
        echo -ne "  ${WHITE}$(t choose):${NC} "
        read -r ch || ch=0
        case "$ch" in
            1) _ga_kmod_enable_interactive ;;
            2) _ga_kmod_program_interactive ;;
            3) _ga_kmod_rebuild_interactive ;;
            4) _ga_kmod_remove_interactive ;;
            0) GA_BACK=1; return 0 ;;
            "") continue ;;
            *) log_error "$(t invalid_choice)" ;;
        esac
        _pause
    done
}

# Состояние экрана: что сейчас (программа или модуль), ядро, движок каждого профиля, причина словами.
_ga_kmod_screen_state() {
    local js st want ver k p eng line row="" removed
    js=$(ga_kmod_status_json)
    st=$(jq -r '.state' <<<"$js"); want=$(jq -r '.want' <<<"$js"); ver=$(jq -r '.version' <<<"$js"); k=$(jq -r '.kernel' <<<"$js")
    case "$st" in
        on)    echo -e "  $(t kmod_now): ${GREEN}$(tf kmod_now_kernel "$ver")${NC}" ;;
        busy)  echo -e "  $(t kmod_now): ${CYAN}$(t kmod_now_busy)${NC}" ;;
        *)     echo -e "  $(t kmod_now): ${CYAN}$(t kmod_now_program)${NC}" ;;
    esac
    echo -e "  $(t kmod_kernel_line): ${CYAN}${k}${NC}"
    # Модуль стоял и удалён (пункт 4) — так и сказать (KMODB-01: экран писал «Модуль ядра не ставился»).
    removed=$(jq -r '.removed_at // ""' <<<"$js")
    case "$st" in
        ready) echo -e "  ${DIM}$(tf kmod_ready_line "$ver")${NC}" ;;
        off)   if [ -n "$removed" ]; then echo -e "  ${DIM}$(_ga_kmod_wrap "$(tf kmod_removed_line "$(ga_human_ts "$removed")")")${NC}"
               else echo -e "  ${DIM}$(t kmod_off_line)${NC}"; fi ;;
    esac
    for p in $(ga_kmod_profiles 2>/dev/null); do
        eng=$(ga_kmod_engine_now "$p" live)
        line=$(ga_profile_line "$p" 2>/dev/null)
        row+="${p} (${line}) — $(_ga_kmod_engine_word "$eng") · "
    done
    [ -n "$row" ] && echo -e "  $(t kmod_profiles_line): ${row% · }"
    case "$st" in
        fallback|failed|unpatched) log_warning "$(_ga_kmod_wrap "$(jq -r '.reason' <<<"$js")")" ;;
    esac
    [ "$want" = program ] && [ "$st" != off ] && echo -e "  ${DIM}$(t kmod_want_program_line)${NC}"
    return 0
}

# _ga_kmod_ask12 <вопрос> [1|2 — по Enter] → 0 — «1», 1 — «2», «0» или конец ввода (как confirm: с терминала).
_ga_kmod_ask12() {
    local q="$1" def="${2:-1}" ans="" i
    for i in 1 2 3; do
        echo -ne "  $(ga_win_wrap "$q" 2) " >&2
        if ! { IFS= read -r ans </dev/tty; } 2>/dev/null; then
            if [ -t 0 ]; then IFS= read -r ans || { GA_INPUT_EOF=1; return 1; }; else GA_INPUT_EOF=1; return 1; fi
        fi
        ans=$(printf '%s' "$ans" | tr -d '[:space:]')
        [ -n "$ans" ] || ans="$def"
        case "$ans" in
            1) return 0 ;;
            2|0) return 1 ;;
        esac
        log_error "$(t invalid_choice)"
    done
    return 1
}

# «Включить»: проверка хоста (одной фразой), что поставится и сколько места, согласие цифрами (рецепт §13), установка с
# ходом в строках, самопроверка, перевод по одному.
_ga_kmod_enable_interactive() {
    local check plan reuse miss size meta mname msize mk="off" res st
    if [ "$(ga_kmod_want)" = kernel ] && [ "$(_ga_kmod_status_field state)" = on ]; then
        log_success "$(t kmod_already_on)"
        return 0
    fi
    log_info "$(t kmod_checking)"
    check=$(ga_kmod_check_json plan)
    if [ "$(jq -r '.ok' <<<"$check")" != true ]; then
        log_warning "$(_ga_kmod_wrap "$(jq -r '.reason' <<<"$check")")"
        return 1
    fi
    reuse=$(jq -r '.reuse' <<<"$check")
    plan=$(jq -c '.plan // {}' <<<"$check")
    echo ""
    if [ "$reuse" = true ]; then
        echo -e "  $(tf kmod_plan_reuse "$(jq -r '.module.ko_version' <<<"$check")")"
    else
        miss=$(jq -r '(.missing // []) | join(", ")' <<<"$plan")
        size=$(jq -r '.size_mb // 0' <<<"$plan")
        if [ -n "$miss" ]; then
            echo -e "  $(_ga_kmod_wrap "$(tf kmod_plan_packages "$miss" "$size")")"
        else
            echo -e "  $(t kmod_plan_no_packages)"
        fi
        echo -e "  ${DIM}$(_ga_kmod_wrap "$(t kmod_plan_build)")${NC}"
        meta=$(jq -c '.headers_meta // null' <<<"$plan")
        if [ "$meta" != null ] && [ "$(jq -r '.installed' <<<"$meta")" != true ]; then
            mname=$(jq -r '.name' <<<"$meta"); msize=$(jq -r '.size_mb' <<<"$meta")
            if [ "$(jq -r '.kernel' <<<"$meta")" = true ]; then
                # KMOD-05: метапакет заголовков тянет новое ядро — отдельный вопрос с размером; по Enter — не ставить.
                echo ""
                echo -e "  $(_ga_kmod_wrap "$(tf kmod_meta_warn "$mname" "$msize")")"
                if _ga_kmod_ask12 "$(t kmod_meta_ask)" 2; then mk=on; fi
            else
                echo -e "  ${DIM}$(_ga_kmod_wrap "$(tf kmod_meta_auto "$mname")")${NC}"
            fi
        fi
    fi
    echo ""
    echo -e "  ${BOLD}$(t kmod_consent_q)${NC}"
    echo -e "  ${CYAN}1${NC}) $(t kmod_consent_yes)"
    echo -e "  ${CYAN}2${NC}) $(t kmod_consent_no)"
    if ! _ga_kmod_ask12 "$(t kmod_consent_prompt)" 1; then
        log_info "$(t kmod_consent_declined)"
        return 0
    fi
    GA_KMOD_APT_WAIT="${GA_KMOD_APT_WAIT:-1800}"
    if ! ga_capture res ga_kmod_install off "$mk"; then
        log_warning "$(t kmod_left_program)"
        return 1
    fi
    _ga_kmod_print_selftest
    st=$(jq -r '.headers_meta_skipped // ""' <<<"$res")
    [ -n "$st" ] && log_dim "$(_ga_kmod_wrap "$(tf kmod_meta_skipped "$st")")"
    echo ""
    log_info "$(_ga_kmod_wrap "$(tf kmod_switch_note "$(ga_kmod_profiles | sed 's/ /, /g')")")"
    _ga_kmod_engine_interactive kernel
}
_ga_kmod_print_selftest() {
    local js row
    js=$(_ga_kmod_state | jq -c '.selftest // {}')
    [ "$(jq -r '.cases | length' <<<"$js" 2>/dev/null)" -gt 0 ] 2>/dev/null || return 0
    echo -e "  $(t kmod_selftest_title)"
    while IFS= read -r row; do
        if [ "$(jq -r '.ok' <<<"$row")" = true ]; then
            echo -e "    ${GREEN}✓${NC} $(tf kmod_selftest_row "$(jq -r '.profile' <<<"$row")" "$(jq -r '.line' <<<"$row")" "$(_ga_kmod_client_word "$(jq -r '.client' <<<"$row")")")"
        else
            echo -e "    ${RED}✗${NC} $(tf kmod_selftest_row "$(jq -r '.profile' <<<"$row")" "$(jq -r '.line' <<<"$row")" "$(_ga_kmod_client_word "$(jq -r '.client' <<<"$row")")") — $(jq -r '.detail' <<<"$row")"
        fi
    done < <(jq -c '.cases[]' <<<"$js")
}
# _ga_kmod_engine_interactive <kernel|program> — перевод: строку по каждому профилю и итог «Профили работают: …» печатает
# сам перевод (ga_kmod_engine_set) по ходу дела; здесь — только отказ целиком. Прежде экран повторял итог и строки
# профилей вторым разом (KMODB-02: «✓ Профили работают: …» дважды в пунктах 1, 2 и 4).
_ga_kmod_engine_interactive() {
    local target="$1" res
    if ! ga_capture res ga_kmod_engine_set "$target"; then
        [ -n "$res" ] || return 1
        log_warning "$(_ga_kmod_wrap "$(tf kmod_rolled_back_all "$(_ga_kmod_engine_word "$target")")")"
    fi
    return 0
}
_ga_kmod_program_interactive() {
    local on
    on=$(_ga_kmod_kernel_profiles)
    if [ -z "$on" ] && [ "$(ga_kmod_want)" != kernel ]; then
        log_info "$(t kmod_already_program)"
        return 0
    fi
    log_warning "$(_ga_kmod_wrap "$(tf kmod_program_warn "$(ga_kmod_profiles | sed 's/ /, /g')")")"
    if ! confirm "$(t kmod_program_ask)"; then log_info "$(t cancelled)"; return 0; fi
    _ga_kmod_engine_interactive program
}
_ga_kmod_rebuild_interactive() {
    local res
    if ! _ga_kmod_ours_src && [ "$(_ga_kmod_state_get '.installed')" != true ]; then
        if ga_kmod_kaskad_present; then log_info "$(t kmod_rebuild_neighbour)"; else log_info "$(t kmod_rebuild_none)"; fi
        return 0
    fi
    log_warning "$(_ga_kmod_wrap "$(tf kmod_rebuild_warn "$(ga_kmod_kernel)")")"
    if ! confirm "$(t kmod_rebuild_ask)"; then log_info "$(t cancelled)"; return 0; fi
    GA_KMOD_APT_WAIT="${GA_KMOD_APT_WAIT:-1800}"
    if ! ga_capture res ga_kmod_install on off; then
        # Где профили теперь — по факту: пересборка с модулем в памяти могла успеть перевести их (KMODB-03).
        local left
        left=$(_ga_kmod_left_words ssh)
        if [ -n "$left" ]; then log_warning "$(_ga_kmod_wrap "$left")"
        else log_warning "$(t kmod_left_program)"; fi
        return 1
    fi
    _ga_kmod_print_selftest
    # Выбран модуль, а профили после перезагрузки в новое ядро ушли на программу — вернуть их на модуль.
    if [ "$(ga_kmod_want)" = kernel ] && [ "$(_ga_kmod_status_field state)" != on ]; then
        _ga_kmod_engine_interactive kernel
    fi
    return 0
}
_ga_kmod_remove_interactive() {
    local res cmd
    if ! _ga_kmod_ours_src && [ "$(_ga_kmod_state_get '.installed')" != true ]; then
        log_info "$(t kmod_remove_none)"
        return 0
    fi
    log_warning "$(_ga_kmod_wrap "$(t kmod_remove_warn)")"
    ga_kmod_kaskad_uses && log_info "$(_ga_kmod_wrap "$(t kmod_remove_neighbour)")"
    if ! confirm "$(t kmod_remove_ask)"; then log_info "$(t cancelled)"; return 0; fi
    if ! ga_capture res ga_kmod_remove; then return 1; fi
    if [ "$(jq -r '.kept_for_neighbour' <<<"$res")" = true ]; then
        log_success "$(t kmod_removed_kept)"
    else
        log_success "$(t kmod_removed)"
    fi
    cmd=$(jq -r '.command // ""' <<<"$res")
    [ -n "$cmd" ] || log_dim "$(t kmod_remove_no_packages)"
    return 0
}

