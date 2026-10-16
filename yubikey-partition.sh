#!/usr/bin/env bash
#
# yubikey-partition.sh - Partition mode for the three-site setup: while this
#                        server can reach no other site, its Radiator logs
#                        users in from a copy of the keys on this server.
#
# VERSION
#   In the file VERSION, next to this script; -V shows it.
#
# HOW IT WORKS
#   Normally each site's Radiator checks every login against the PostgreSQL
#   primary, and rejects every login while it can't reach one. With this
#   script running, as yubikey-partition.service:
#     - Every SYNC seconds it updates a copy of the yubikeys table, in SQLite
#       (/var/lib/yubikey-partition/keys.db), from this server's own
#       PostgreSQL (a standby or the primary), through the local socket. The
#       copy's counters only move forward.
#     - Every INTERVAL seconds it checks whether the servers in PEERS answer
#       on one of PORTS. When none has for ENTER checks in a row, it updates
#       the copy once more (a standby that is cut off still answers, with
#       everything up to the cut) and enters partition mode: it points
#       Radiator's /etc/radiator/conf.d/yubikey.conf at yubikey-partition.conf
#       (the copy) instead of yubikey-cluster.conf, and restarts Radiator.
#       Logins at this site work again, and their counters are saved in the
#       copy. If this server's PostgreSQL doesn't answer then (it was the
#       primary, and Patroni is stopping it for about a minute), the copy is
#       the one from the last SYNC, and it is updated at every check until
#       PostgreSQL answers again, as a standby.
#     - When a peer answers and the primary can be reached for LEAVE checks
#       in a row, it copies the counters that moved forward in the copy to
#       the primary (only forward), points yubikey.conf back at the cluster,
#       restarts Radiator, and copies them once more, for logins in between.
#   The risks: while this site is cut off, an OTP used at another site can
#   be used once more here (on a former primary, also one used up to SYNC
#   seconds before the cut, until its PostgreSQL answers again), and the
#   other way round until the counters are copied back; and changes made
#   elsewhere, such as a disabled user, reach this site only when the
#   network is back.
#
# COMMANDS
#   setup     Make the copy, Radiator's clause for it (yubikey-partition.conf)
#             and the link yubikey.conf -> yubikey-cluster.conf (moving an
#             existing yubikey.conf to yubikey-cluster.conf)
#   run       Run the service
#   status    Show the mode, the copy and the peers; exits 0 in normal mode
#   sync      Update the copy from this server's PostgreSQL now
#   leave     Leave partition mode now: copy the counters to the primary,
#             point yubikey.conf back at the cluster, restart Radiator
#
# OPTIONS
#   -c FILE   The settings (default /etc/radiator/partition.conf)
#
# FILES
#   /etc/radiator/partition.conf           settings (see
#                                          yubikey-partition.example.conf)
#   /etc/radiator/conf.d/yubikey-cluster.conf
#                                          Radiator's clause for PostgreSQL
#                                          (from 'yubikey-db.sh -b pg config')
#   /etc/radiator/conf.d/yubikey-partition.conf
#                                          Radiator's clause for the copy
#   /etc/radiator/conf.d/yubikey.conf      a link to one of the two
#   /var/lib/yubikey-partition/keys.db     the copy (every AES key)
#   /var/lib/yubikey-partition/merge-pending
#                                          counters still to be copied back
#   /run/yubikey-partition/status          the state, written by 'run'
#
# PREREQUISITES
#   Ubuntu 26.04 LTS, as root, on a server of the three-site setup (with
#   PostgreSQL under Patroni and Radiator). psql, sqlite3, setpriv, and the
#   Perl module DBD::SQLite (libdbd-sqlite3-perl) for Radiator. 'setup' also
#   needs yubikey-db.sh, in the same directory or on the PATH.
#
# EXIT STATUS
#   0 success (status: normal mode); 1 a step failed (status: partition
#   mode); 3 a problem with the settings or the system, which a restart of
#   the service won't fix.
#
# ENVIRONMENT (for tests)
#   PARTITION_STATE_DIR  instead of /var/lib/yubikey-partition
#   PARTITION_RUN_DIR    instead of /run/yubikey-partition
#   PARTITION_CONF_D     instead of /etc/radiator/conf.d
#   PARTITION_LOCAL_DB   the local database (default yubikey); as a user
#                        other than root, psql connects as that user
#   PARTITION_OWNER      the copy's owner (default radiator:radiator; empty:
#                        unchanged)
#   PSQL, SQLITE3, SYSTEMCTL, YUBIKEY_DB_SH
#                        the commands to use

set -uo pipefail
umask 027

PROG=${0##*/}
# The version is in the file VERSION, next to this script (the package has it
# written here instead).
VERSION=$(cat -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")/VERSION" 2>/dev/null) || VERSION=unknown
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
CONF=/etc/radiator/partition.conf
STATE_DIR=${PARTITION_STATE_DIR:-/var/lib/yubikey-partition}
RUN_DIR=${PARTITION_RUN_DIR:-/run/yubikey-partition}
CONF_D=${PARTITION_CONF_D:-/etc/radiator/conf.d}
LOCAL_DB=${PARTITION_LOCAL_DB:-yubikey}
OWNER=${PARTITION_OWNER-radiator:radiator}
PSQL=${PSQL:-psql}
SQLITE3=${SQLITE3:-sqlite3}
SYSTEMCTL=${SYSTEMCTL:-systemctl}
COPY=$STATE_DIR/keys.db
CLUSTER_CONF=$CONF_D/yubikey-cluster.conf
COPY_CONF=$CONF_D/yubikey-partition.conf
LINK=$CONF_D/yubikey.conf

# Settings, from the settings file
PEERS='' PORTS='5432 8008' INTERVAL=5 ENTER=3 LEAVE=2 SYNC=300

die() { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 3; }
log() { printf '%s\n' "$*"; }

# yubikeys N: "1 YubiKey", "2 YubiKeys".
yubikeys() { if [[ $1 == 1 ]]; then echo "1 YubiKey"; else echo "$1 YubiKeys"; fi; }

# copy_read SQLITE3-OPTIONS... SQL: a query on the copy. Like every use of
# the copy, it waits up to 10 s for a writer to finish (Radiator saving a
# counter in partition mode, or sync_copy), instead of failing at once with
# "database is locked".
copy_read() { "$SQLITE3" -batch -cmd '.timeout 10000' "${@:1:$#-1}" "$COPY" "${!#}"; }
copy_size() {
    local n
    n=$(copy_read 'SELECT count(*) FROM yubikeys' 2>/dev/null) && [[ $n =~ ^[0-9]+$ ]] || n='?'
    yubikeys "$n"
}

usage() {
    cat <<EOF
Usage: $PROG [-c FILE] COMMAND

Commands:
  setup     Make the copy, Radiator's clause for it (yubikey-partition.conf)
            and the link yubikey.conf -> yubikey-cluster.conf (moving an
            existing yubikey.conf to yubikey-cluster.conf)
  run       Run the service (yubikey-partition.service does this)
  status    Show the mode, the copy and the peers; exits 0 in normal mode
  sync      Update the copy from this server's PostgreSQL now
  leave     Leave partition mode now: copy the counters to the primary,
            point yubikey.conf back at the cluster, restart Radiator

Options:
  -c FILE   The settings (default $CONF)
  -h        Show this help
  -V        Show the version
EOF
}

# --------------------------------------------------------------------------
# Settings
# --------------------------------------------------------------------------

conf_pair() {
    case $1 in
        PEERS|PORTS|INTERVAL|ENTER|LEAVE|SYNC) printf -v "$1" '%s' "$2" ;;
        *) die "$CONF line $3: unknown setting '$1'" ;;
    esac
}

# NAME=value lines; blank lines and lines starting with # are skipped, and a
# value may be in quotes. The file is never run as shell code.
load_conf() {
    local line n=0 name value
    [[ -f $CONF && -r $CONF ]] || die "cannot read $CONF"
    while IFS= read -r line || [[ -n $line ]]; do
        n=$((n + 1))
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line =~ ^[[:space:]]*([A-Za-z_]+)[[:space:]]*=(.*)$ ]] || die "$CONF line $n: expected NAME=value"
        name=${BASH_REMATCH[1]} value=${BASH_REMATCH[2]}
        value=${value#"${value%%[![:space:]]*}"} value=${value%"${value##*[![:space:]]}"}
        if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
        conf_pair "$name" "$value" "$n"
    done <"$CONF"
    [[ -n $PEERS ]] || die "$CONF: PEERS is not set"
    local p
    for p in $PEERS; do
        [[ $p =~ ^[A-Za-z0-9.:-]+$ ]] || die "$CONF: '$p' in PEERS is not a host name or address"
    done
    for p in $PORTS; do
        if ! [[ $p =~ ^[0-9]{1,5}$ ]] || ((10#$p < 1 || 10#$p > 65535)); then die "$CONF: '$p' in PORTS is not a port"; fi
    done
    [[ -n $PORTS ]] || die "$CONF: PORTS is empty"
    number INTERVAL 1 3600
    number ENTER 1 100
    number LEAVE 1 100
    number SYNC 1 86400
}

# number NAME MIN MAX: check the setting NAME.
number() {
    local v=${!1}
    if ! [[ $v =~ ^[0-9]{1,5}$ ]] || ((10#$v < $2 || 10#$v > $3)); then
        die "$CONF: $1 must be a number from $2 to $3"
    fi
    printf -v "$1" '%d' "$((10#$v))"
}

# --------------------------------------------------------------------------
# The two databases
# --------------------------------------------------------------------------

# local_psql ARGS...: psql in this server's own PostgreSQL, through the local
# socket, as postgres (as the current user when not root).
local_psql() {
    if [[ $EUID -eq 0 ]]; then
        # setpriv, not runuser: no PAM session (and no log lines) every time.
        setpriv --reuid=postgres --regid=postgres --init-groups env -u PGHOST -u PGPORT -u PGUSER -u PGSERVICE \
            HOME=/var/lib/postgresql "$PSQL" -X -q -At -v ON_ERROR_STOP=1 -d "$LOCAL_DB" "$@"
    else
        "$PSQL" -X -q -At -v ON_ERROR_STOP=1 -d "$LOCAL_DB" "$@"
    fi
}

# cluster_psql ARGS...: psql to the primary, with Radiator's own login and
# connection settings from yubikey-cluster.conf (its DBSource, DBUsername and
# DBAuth). The password goes through a password file, never a command line.
cluster_psql() {
    local dsn user pass conninfo pf rc
    dsn=$(sed -n 's/^[[:space:]]*DBSource[[:space:]]\{1,\}dbi:Pg:\([^[:space:]]*\).*/\1/p' "$CLUSTER_CONF" | head -1)
    user=$(sed -n 's/^[[:space:]]*DBUsername[[:space:]]\{1,\}\([^[:space:]]*\).*/\1/p' "$CLUSTER_CONF" | head -1)
    pass=$(sed -n 's/^[[:space:]]*DBAuth[[:space:]]\{1,\}\(.*[^[:space:]]\)[[:space:]]*$/\1/p' "$CLUSTER_CONF" | head -1)
    [[ -n $dsn ]] || { echo "no DBSource dbi:Pg: line in $CLUSTER_CONF"; return 1; }
    conninfo=${dsn//;/ }
    [[ -n $user ]] && conninfo+=" user=$user"
    mkdir -p "$RUN_DIR" || return 1
    pf=$RUN_DIR/pgpass
    pass=${pass//\\/\\\\}
    printf '*:*:*:*:%s\n' "${pass//:/\\:}" >"$pf" && chmod 0600 "$pf" || return 1
    PGPASSFILE=$pf "$PSQL" -X -q -At -v ON_ERROR_STOP=1 -d "$conninfo" "$@" 2>&1
    rc=$?
    rm -f "$pf"
    return $rc
}

# find_ydb: print the path of yubikey-db.sh (next to this script, or on the
# PATH), or fail.
find_ydb() {
    local ydb=${YUBIKEY_DB_SH:-}
    if [[ -z $ydb ]]; then
        if [[ -x $HERE/yubikey-db.sh ]]; then ydb=$HERE/yubikey-db.sh; else ydb=$(command -v yubikey-db.sh) || true; fi
    fi
    [[ -n $ydb ]] || { echo "yubikey-db.sh not found (put it next to $PROG or on the PATH)"; return 1; }
    echo "$ydb"
}

# The service-account and group tables, in the order they are filled. The
# copy gets what Radiator reads; they are small, so they are copied whole.
GROUP_TABLES=(service_accounts user_groups group_members group_access group_rules)
GROUP_ROWS=(
    "format('INSERT INTO service_accounts (username, password, active) VALUES (%L, %L, %s);', username, password, active) FROM service_accounts"
    "format('INSERT INTO user_groups (name) VALUES (%L);', name) FROM user_groups"
    "format('INSERT INTO group_members (user_group, username) VALUES (%L, %L);', user_group, username) FROM group_members"
    "format('INSERT INTO group_access (user_group, device_group, priv_lvl, radius_reply) VALUES (%L, %L, %s, %L);', user_group, device_group, priv_lvl, radius_reply) FROM group_access"
    "format('INSERT INTO group_rules (user_group, device_group, seq, rule) VALUES (%L, %L, %s, %L);', user_group, device_group, seq, rule) FROM group_rules"
)

# sync: make the copy match this server's PostgreSQL, except that its
# counters only move forward. A YubiKey whose keys changed (or that is gone)
# is replaced (or removed); its counters start again from the database's.
# The service accounts and groups are replaced whole, when this server's
# PostgreSQL has them (a copy made before they existed gets their tables).
sync_copy() {
    local rows out groups='' t q ydb
    rows=$(local_psql -c "SELECT format('INSERT INTO src VALUES (%L, %L, %L, %L, %L, %L, %L, %L, %L);',
                                username, password, active, tokenId, userId, secret, counter, low, high)
                          FROM yubikeys" 2>&1) || { echo "cannot read this server's PostgreSQL: ${rows%%$'\n'*}"; return 1; }
    out=$(local_psql -c "SELECT to_regclass('group_rules') IS NOT NULL" 2>&1) \
        || { echo "cannot read this server's PostgreSQL: ${out%%$'\n'*}"; return 1; }
    if [[ $out == t ]]; then
        if [[ $(copy_read "SELECT count(*) FROM sqlite_master WHERE name = 'group_rules'" 2>/dev/null) != 1 ]]; then
            ydb=$(find_ydb) || return 1
            out=$("$ydb" -d "$COPY" init ${OWNER:+--owner "$OWNER"} 2>&1) \
                || { echo "cannot add the group tables to the copy: ${out%%$'\n'*}"; return 1; }
        fi
        for q in "${GROUP_ROWS[@]}"; do
            out=$(local_psql -c "SELECT $q" 2>&1) || { echo "cannot read this server's PostgreSQL: ${out%%$'\n'*}"; return 1; }
            groups+=$out${out:+$'\n'}
        done
        for ((t = ${#GROUP_TABLES[@]} - 1; t >= 0; t--)); do
            groups="DELETE FROM ${GROUP_TABLES[t]};"$'\n'$groups
        done
    fi
    out=$({
        printf '.bail on\n.timeout 10000\nBEGIN IMMEDIATE;\n'
        printf 'CREATE TEMP TABLE src (username text, password text, active int, tokenId text, userId text,\n'
        printf '    secret text, counter int, low int, high int);\n'
        printf '%s\n' "$rows"
        printf '%s' "$groups"
        cat <<'EOF'
DELETE FROM yubikeys WHERE NOT EXISTS (SELECT 1 FROM src s WHERE s.userId = yubikeys.userId
    AND s.tokenId = yubikeys.tokenId AND s.secret = yubikeys.secret);
INSERT INTO yubikeys (username, password, active, created, accessed, tokenId, userId, secret, counter, low, high)
    SELECT username, password, active, CURRENT_TIMESTAMP, '', tokenId, userId, secret, counter, low, high
    FROM src WHERE userId NOT IN (SELECT userId FROM yubikeys);
UPDATE yubikeys SET username = s.username, password = s.password, active = s.active FROM src s
    WHERE s.userId = yubikeys.userId AND (yubikeys.username IS NOT s.username
        OR yubikeys.password IS NOT s.password OR yubikeys.active IS NOT s.active);
UPDATE yubikeys SET counter = s.counter, low = s.low, high = s.high FROM src s
    WHERE s.userId = yubikeys.userId AND s.counter IS NOT NULL
      AND (yubikeys.counter IS NULL OR s.counter > yubikeys.counter
           OR (s.counter = yubikeys.counter AND coalesce(s.low, 0) > coalesce(yubikeys.low, 0)));
COMMIT;
EOF
    } | "$SQLITE3" -batch "$COPY" 2>&1) || { echo "cannot update the copy: ${out%%$'\n'*}"; return 1; }
    return 0
}

# merge: copy the counters that are ahead in the copy to the primary, only
# forward. Prints how many YubiKeys moved forward.
merge() {
    local rows uid tok c l acc values='' out
    rows=$(copy_read -noheader -separator ' ' \
        "SELECT userId, tokenId, counter, coalesce(low, 0), coalesce(replace(accessed, ' ', 'T'), '-')
         FROM yubikeys WHERE counter IS NOT NULL" 2>&1) || { echo "cannot read the copy: ${rows%%$'\n'*}"; return 1; }
    while read -r uid tok c l acc; do
        [[ $uid =~ ^[0-9a-f]{12}$ && $tok =~ ^[cbdefghijklnrtuv]{12}$ && $c =~ ^[0-9]{1,6}$ && $l =~ ^[0-9]{1,3}$ ]] || continue
        if [[ $acc =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}$ ]]; then acc="'$acc+00'"; else acc=NULL; fi
        values+="${values:+,}('$uid','$tok',$c,$l,$acc::timestamptz)"
    done <<<"$rows"
    [[ -n $values ]] || { echo 0; return 0; }
    out=$(cluster_psql -c "WITH moved AS (
        UPDATE yubikeys AS y SET counter = v.counter, low = v.low, accessed = coalesce(v.accessed, now())
        FROM (VALUES $values) AS v(userid, tokenid, counter, low, accessed)
        WHERE y.userId = v.userid AND y.tokenId = v.tokenid
          AND (y.counter IS NULL OR v.counter > y.counter OR (v.counter = y.counter AND v.low > coalesce(y.low, 0)))
        RETURNING 1)
        SELECT count(*) FROM moved") || { echo "cannot copy the counters to the primary: ${out%%$'\n'*}"; return 1; }
    echo "$out"
}

# --------------------------------------------------------------------------
# The mode
# --------------------------------------------------------------------------

mode() {
    case $(readlink "$LINK" 2>/dev/null) in
        yubikey-partition.conf) echo partition ;;
        yubikey-cluster.conf)   echo normal ;;
        *)                      echo unknown ;;
    esac
}

# point TARGET: make yubikey.conf a link to TARGET, in one step.
point() {
    if ! { ln -sfn "$1" "$LINK.new" && mv -Tf "$LINK.new" "$LINK"; }; then die "cannot change $LINK"; fi
}

restart_radiator() {
    "$SYSTEMCTL" restart radiator || log "error: could not restart Radiator"
}

# The peers that answer on one of PORTS within 2 s, all tried at once.
answering() {
    local p port pids=() hosts=() up=() i
    for p in $PEERS; do
        for port in $PORTS; do
            # shellcheck disable=SC2016  # $0 and $1 are the inner shell's
            timeout 2 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$p" "$port" 2>/dev/null &
            pids+=($!) hosts+=("$p")
        done
    done
    for i in "${!pids[@]}"; do
        if wait "${pids[i]}"; then up+=("${hosts[i]}"); fi
    done
    if ((${#up[@]})); then printf '%s\n' "${up[@]}" | sort -u | paste -sd' '; fi
}

# leave_partition: copy the counters back, return to the cluster, and copy
# again. Fails (and changes nothing) if the first copy fails.
leave_partition() {
    local n out
    n=$(merge) || { log "error: $n"; return 1; }
    point yubikey-cluster.conf
    restart_radiator
    if out=$(merge); then
        rm -f "$STATE_DIR/merge-pending"
        log "normal mode: Radiator uses the cluster again; counters moved forward in the primary for $(yubikeys $((n + out)))"
    else
        log "normal mode: Radiator uses the cluster again; counters moved forward in the primary for $(yubikeys "$n"), the rest later ($out)"
    fi
}

# --------------------------------------------------------------------------
# Commands
# --------------------------------------------------------------------------

cmd_setup() {
    local ydb out
    load_conf
    ydb=$(find_ydb) || die "$ydb"
    command -v "$SQLITE3" >/dev/null || die "$SQLITE3 not found (sudo apt install sqlite3)"
    if [[ $EUID -eq 0 ]] && ! perl -MDBD::SQLite -e 1 2>/dev/null; then
        die "Radiator needs DBD::SQLite for the copy (sudo apt install libdbd-sqlite3-perl)"
    fi
    [[ -d $CONF_D ]] || die "$CONF_D not found"
    if [[ -f $LINK && ! -L $LINK ]]; then
        [[ ! -e $CLUSTER_CONF ]] || die "both $LINK and $CLUSTER_CONF exist: keep one"
        mv "$LINK" "$CLUSTER_CONF" || die "cannot move $LINK"
        log "moved yubikey.conf to yubikey-cluster.conf (in $CONF_D)"
    fi
    [[ -f $CLUSTER_CONF ]] || die "no $CLUSTER_CONF (write it with 'yubikey-db.sh -b pg config')"
    grep -q 'dbi:Pg:' "$CLUSTER_CONF" || die "$CLUSTER_CONF has no PostgreSQL DBSource"
    # init also brings a copy made by an older version up to date.
    out=$("$ydb" -d "$COPY" init ${OWNER:+--owner "$OWNER"} 2>&1) || die "cannot make the copy: $out"
    out=$(sync_copy) || die "$out"
    "$ydb" -d "$COPY" config >"$COPY_CONF.new" || die "cannot write $COPY_CONF"
    if [[ $EUID -eq 0 ]]; then chown root:radiator "$COPY_CONF.new"; fi
    if ! { chmod 0640 "$COPY_CONF.new" && mv -f "$COPY_CONF.new" "$COPY_CONF"; }; then die "cannot write $COPY_CONF"; fi
    [[ -L $LINK ]] || point yubikey-cluster.conf
    log "the copy: $COPY, $(copy_size)"
    log "Radiator's clause: yubikey.conf -> $(readlink "$LINK"); in partition mode -> yubikey-partition.conf"
}

cmd_sync() {
    local out
    load_conf
    out=$(sync_copy) || { log "error: $out"; return 1; }
    log "copy: $(copy_size)"
}

cmd_leave() {
    load_conf
    [[ $(mode) == partition ]] || { log "not in partition mode"; return 0; }
    leave_partition
}

cmd_status() {
    local -A st=()
    local name value m
    load_conf
    m=$(mode)
    if [[ -f $RUN_DIR/status ]]; then
        while IFS='=' read -r name value; do st[$name]=$value; done <"$RUN_DIR/status"
        printf '%s mode since %s\n' "$m" "$(date -d "@${st[since]}" '+%F %T %Z')"
        printf 'peers answering: %s\n' "${st[peers]:-none}"
        printf 'copy: %s\n' "${st[copy]}"
    else
        printf '%s mode; the service is not running\n' "$m"
    fi
    printf 'Radiator uses: %s\n' "$(readlink "$LINK" 2>/dev/null || echo "?")"
    if [[ -f $STATE_DIR/merge-pending ]]; then printf 'counters to copy to the primary: yes\n'; fi
    [[ $m == normal ]]
}

cmd_run() {
    local m since lonely=0 back=0 peers copy='not updated yet' synced='' fresh=1 failed='' last='' n start note
    load_conf
    [[ -f $COPY && -L $LINK && -f $CLUSTER_CONF && -f $COPY_CONF ]] || die "run '$PROG setup' first"
    mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
    m=$(mode)
    [[ $m != unknown ]] || die "$LINK points at neither clause"
    since=$(date +%s)
    [[ $m == partition ]] && fresh=0
    log "started in $m mode: partition mode after $ENTER checks ($((ENTER * INTERVAL)) s) in which none of $PEERS answers; the copy is updated every $SYNC s"
    trap 'rm -f "$RUN_DIR/status"; exit 0' TERM INT HUP

    # pull: update the copy from this server's PostgreSQL. Sets copy (what
    # it holds, and when) and synced, or failed (why it couldn't).
    pull() {
        if failed=$(sync_copy); then
            copy="$(copy_size), updated $(date '+%T')" synced=$SECONDS failed=''
        else
            return 1
        fi
    }

    while :; do
        start=$SECONDS
        # Every SYNC seconds; in partition mode, at every check until a pull
        # has worked since it began.
        if [[ -z $synced ]] || ((SECONDS - synced >= SYNC)) || [[ $m == partition && $fresh == 0 ]]; then
            if pull; then
                if [[ $m == partition && $fresh == 0 ]]; then
                    log "copy: updated from this server's PostgreSQL again ($copy)"
                elif [[ $last != ok ]]; then
                    log "copy: $copy"
                fi
                last=ok fresh=1
            elif [[ $last != "$failed" ]]; then
                log "copy: $failed"
                last=$failed
            fi
        fi
        peers=$(answering)
        if [[ $m == normal ]]; then
            if [[ -f $STATE_DIR/merge-pending ]]; then
                if n=$(merge); then
                    rm -f "$STATE_DIR/merge-pending"
                    log "counters moved forward in the primary for $(yubikeys "$n")"
                fi
            fi
            if [[ -z $peers ]]; then lonely=$((lonely + 1)); else lonely=0; fi
            if ((lonely >= ENTER)); then
                # Once more: a standby that is cut off still answers, with
                # everything up to the cut.
                if pull; then
                    note="$(copy_size), updated just now" fresh=1 last=ok
                else
                    note="$copy; $failed" fresh=0
                fi
                touch "$STATE_DIR/merge-pending"
                point yubikey-partition.conf
                restart_radiator
                m=partition since=$(date +%s) back=0
                log "partition mode: none of $PEERS answered in $lonely checks; Radiator uses this server's copy of the keys ($note)"
            fi
        else
            if [[ -n $peers ]] && cluster_psql -c 'SELECT 1' >/dev/null; then back=$((back + 1)); else back=0; fi
            if ((back >= LEAVE)) && leave_partition; then
                m=normal since=$(date +%s) lonely=0 fresh=1 synced=''
            fi
        fi
        printf '%s\n' "since=$since" "peers=$peers" "copy=$copy" \
            >"$RUN_DIR/status.new" && mv -f "$RUN_DIR/status.new" "$RUN_DIR/status"
        if ((SECONDS - start < INTERVAL)); then
            sleep $((INTERVAL - (SECONDS - start))) &
            wait $!
        fi
    done
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -c)                   CONF=${2:?-c needs a file}; shift 2 ;;
        -h|--help|help)       usage; exit 0 ;;
        -V|--version|version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        -*)                   die "unknown option '$1' (see '$PROG help')" ;;
        *)                    break ;;
    esac
done
[[ $# -eq 1 ]] || { usage >&2; exit 3; }

case $1 in
    setup)  cmd_setup ;;
    run)    cmd_run ;;
    status) cmd_status ;;
    sync)   cmd_sync ;;
    leave)  cmd_leave ;;
    *)      die "unknown command '$1' (see '$PROG help')" ;;
esac
