# shellcheck shell=bash
#
# turnkey-lib.sh - The lab of the turn-key tests (turnkey.sh, upgrade.sh),
# sourced by them after they set root (the repository), image (the test
# image that run.sh builds) and rads (the Radiator packages):
#
#   yk-tk-east1  172.31.99.11  the usual primary         router: rtr1
#   yk-tk-east2  .12                                     router: rtr1
#   yk-tk-west   .13           the last resort           routers: rtr1 and rtr2
#   yk-tk-rtr1   .2            FRR, preferring West, then East1, then East2;
#                              also on yk-tk-nas (172.31.100.0/24) as .2
#   yk-tk-rtr2   .3            FRR, West's second router
#   yk-tk-nas    172.31.100.10 a device in device group core, and the
#                              admins' machine (the admin subnet)
#
# lab_start removes a lab left from before (and this one at the end, unless
# KEEP=1); lab_prepare makes the servers' image, the networks and the
# admins' volume (/lab, with the packages in /lab/pkgs); lab_machines starts
# the servers, the routers and the device. The rest are helpers: check,
# on NAME COMMAND, members, routes, radius, tac, admin, gen, secret, ...

# shellcheck disable=SC2016  # the containers' shells expand the commands given to "on"
# shellcheck disable=SC2034,SC2154  # the variables are the callers' (root, image, rads), or theirs to use

pass=0 fail=0
SITES=(east1 east2 west)
BASE=yk-turnkey-base:26.04

declare -A IP=([east1]=172.31.99.11 [east2]=172.31.99.12 [west]=172.31.99.13 [rtr1]=172.31.99.2 [rtr2]=172.31.99.3
               [east1b]=172.31.99.15)
declare -A IP6=([east1]=fd53:99::11 [east2]=fd53:99::12 [west]=fd53:99::13 [rtr1]=fd53:99::2 [rtr2]=fd53:99::3
                [east1b]=fd53:99::15)
NAS4=172.31.100.10 NAS6=fd53:100::10 NAS_NET4=172.31.100.0/24 NAS_NET6=fd53:100::/64
ANY4=192.0.2.153 ANY6=2001:db8:153::153
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
DOMAIN=tk.test

remove_lab() {
    docker rm -f yk-tk-east1 yk-tk-east1b yk-tk-east2 yk-tk-west yk-tk-rtr1 yk-tk-rtr2 yk-tk-nas >/dev/null 2>&1
    docker network rm yk-tk yk-tk-nas >/dev/null 2>&1
    docker volume rm yk-tk-lab >/dev/null 2>&1
}

# lab_start: no lab left from before; removed at the end, unless KEEP=1.
lab_start() {
    remove_lab
    if [[ ${KEEP-} == 1 ]]; then
        trap 'echo "KEEP=1: the containers are still running"' EXIT
    else
        trap remove_lab EXIT
    fi
}

# check LABEL EXPECTED ACTUAL: count and print one result.
check() {
    if [[ $3 == "$2" ]]; then
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# check_match LABEL REGEX ACTUAL (of more than a line, only the match shown)
check_match() {
    if [[ $3 =~ $2 ]]; then
        local shown=$3
        [[ $3 == *$'\n'* ]] && shown=${BASH_REMATCH[0]}
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$shown"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected /%s/, got %s\n' "$1" "$2" "$3"
    fi
}

# on NAME COMMAND: run COMMAND with bash in container yk-tk-NAME.
on() { docker exec "yk-tk-$1" bash -c "$2"; }

# booted NAME: wait for systemd on NAME to finish starting its services.
booted() {
    local s
    for _ in $(seq 120); do
        s=$(docker exec "yk-tk-$1" systemctl is-system-running 2>/dev/null)
        [[ $s == running || $s == degraded ]] && return 0
        sleep 0.5
    done
    echo "$1 did not finish booting ($s)"
    return 1
}

# until_eq SECONDS EXPECTED COMMAND: run COMMAND (in this shell) every second
# until it prints EXPECTED; print what it printed last.
until_eq() {
    local secs=$1 want=$2 got=''
    shift 2
    for _ in $(seq "$secs"); do
        got=$("$@" 2>/dev/null)
        [[ $got == "$want" ]] && break
        sleep 1
    done
    printf '%s\n' "$got"
}

# until_match SECONDS REGEX COMMAND: the same, until it matches REGEX.
until_match() {
    local secs=$1 re=$2 got=''
    shift 2
    for _ in $(seq "$secs"); do
        got=$("$@" 2>/dev/null)
        [[ $got =~ $re ]] && break
        sleep 1
    done
    printf '%s\n' "$got"
}

# status NAME: setup.sh --status on NAME, as "EXIT-STATUS FIRST-LINE" (all
# of it in NAME's /tmp/status.out).
status() { on "$1" '/root/turnkey/setup.sh --status >/tmp/status.out 2>&1; echo "$? $(head -1 /tmp/status.out)"'; }

# check_status LABEL NAME REGEX: wait up to 60 s for NAME's --status to
# match REGEX; show all of it when it doesn't.
check_status() {
    local got
    got=$(until_match 60 "$3" status "$2")
    check_match "$1" "$3" "$got"
    [[ $got =~ $3 ]] || on "$2" 'cat /tmp/status.out'
}

# lab ' COMMAND': COMMAND on the admins' machine, which has /lab (the
# packages, site.toml, secrets.toml and out/), the repository and Radiator's
# packages.
lab() { docker run --rm -v "$root:/repo:ro" -v "$rads:/radiator:ro" -v yk-tk-lab:/lab "$image" bash -c "$1"; }

# lab_prepare: the servers' image, the networks, and the admins' volume with
# the packages (in /lab/pkgs) and the backups' key pair.
lab_prepare() {
    echo "Building $BASE (a fresh Ubuntu 26.04 server: systemd, iproute2) ..."
    docker build -q -t "$BASE" - >/dev/null <<'EOF' || exit 1
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends systemd systemd-sysv dbus iproute2 \
 && rm -rf /var/lib/apt/lists/*
EOF
    docker network create --ipv6 --subnet 172.31.99.0/24 --subnet fd53:99::/64 yk-tk >/dev/null || exit 1
    docker network create --ipv6 --subnet 172.31.100.0/24 --subnet fd53:100::/64 yk-tk-nas >/dev/null || exit 1
    docker volume create yk-tk-lab >/dev/null || exit 1
    lab 'mkdir -p /lab/pkgs && /repo/packaging/build-deb.sh /lab/pkgs >/dev/null && cp /radiator/*.deb /lab/pkgs/' || exit 1
    # The backups' key pair, as the guide makes it (with the passphrase given
    # here instead of asked).
    lab 'cd /lab && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -aes-256-cbc -pass pass:lab-only -out backup.key \
         && openssl req -new -x509 -key backup.key -passin pass:lab-only -days 7300 -subj "/CN=yubikey backups" -out backup.crt' \
        || exit 1
}

site_toml() {
    cat <<EOF
# The lab of tests/radiator/turnkey.sh.
[site]
name = "Turnkey lab"

[[server]]
name = "east1"
fqdn = "east1.$DOMAIN"
ipv4 = "${IP[east1]}"
ipv6 = "${IP6[east1]}"
[[server.router]]
name = "rtr1"
ipv4 = "${IP[rtr1]}"
ipv6 = "${IP6[rtr1]}"
asn = 64500

[[server]]
name = "east2"
fqdn = "east2.$DOMAIN"
ipv4 = "${IP[east2]}"
ipv6 = "${IP6[east2]}"
[[server.router]]
name = "rtr1"
ipv4 = "${IP[rtr1]}"
ipv6 = "${IP6[rtr1]}"
asn = 64500

[[server]]
name = "west"
fqdn = "west.$DOMAIN"
ipv4 = "${IP[west]}"
ipv6 = "${IP6[west]}"
last_resort = true
[[server.router]]
name = "rtr1"
ipv4 = "${IP[rtr1]}"
ipv6 = "${IP6[rtr1]}"
asn = 64500
[[server.router]]
name = "rtr2"
ipv4 = "${IP[rtr2]}"
ipv6 = "${IP6[rtr2]}"
asn = 64500

[anycast]
ipv4 = "$ANY4"
ipv6 = "$ANY6"
asn = 65053

[admin]
logins = ["opsadmin"]
subnets = ["$NAS_NET4", "$NAS_NET6"]

[[device]]
address = "$NAS4"
group = "core"
name = "nas"

[[device]]
address = "$NAS6"
group = "core"
name = "nas (IPv6)"

[[device]]
address = "172.31.100.64/26"
group = "access"

[[group]]
name = "netadmins"
access = [ { devices = "core", level = 15, reply = 'Reply-Message="netadmins"' } ]

[[group]]
name = "helpdesk"
access = [ { devices = "access", level = 1, rules = ["permit service=shell cmd=show"] } ]

[backup]
certificate = "backup.crt"
keep = 3
$1
EOF
}

gen() { lab "cd /lab && python3 /repo/yubikey-turnkey $1 2>&1"; }

# secret PATH: a value from secrets.toml, such as device.172.31.100.10.secret.
secret() {
    lab "python3 -c 'import sys, tomllib
d = tomllib.load(open(\"/lab/secrets.toml\", \"rb\"))
for k in sys.argv[1].split(\"|\"): d = d[k]
print(d)' '$1'"
}

# SYS_PTRACE: root reads every process's /proc/PID/exe, as on a server (for
# needrestart). SIGRTMIN+3 makes systemd shut down cleanly, so 'docker restart' is a clean
# reboot. The servers may bind to addresses they don't have (Docker mounts
# /proc/sys read-only, so setup.sh can't set this itself; it checks it).
# Docker writes /etc/hosts anew at each start, without setup.sh's lines: it
# gets the servers' names too, as DNS would. TURNKEY_WAIT=300: every setup.sh
# run in the lab waits at most 5 min for the other servers, not 30, so a lab
# that hangs fails within minutes.
names=(--add-host "east1.$DOMAIN:${IP[east1]}" --add-host "east2.$DOMAIN:${IP[east2]}" --add-host "west.$DOMAIN:${IP[west]}")
# server NAME: a fresh server (also for one rebuilt).
server() {
    docker run -d --name "yk-tk-$1" --hostname "$1" --network yk-tk --ip "${IP[$1]}" --ip6 "${IP6[$1]}" "${names[@]}" \
        --sysctl net.ipv4.ip_nonlocal_bind=1 --sysctl net.ipv6.ip_nonlocal_bind=1 \
        --cap-add SYS_ADMIN --cap-add NET_ADMIN --cap-add SYS_PTRACE --security-opt apparmor=unconfined --cgroupns private \
        --tmpfs /run --tmpfs /run/lock --stop-signal SIGRTMIN+3 -v yk-tk-lab:/lab:ro -e TURNKEY_WAIT=300 \
        "$BASE" sh -c 'mount -o remount,rw /sys/fs/cgroup && exec /lib/systemd/systemd' >/dev/null
}
# The network around the servers: their routes to the device's network
# through rtr1, kept across reboots (the lab's, not setup.sh's job).
lab_route() {
    on "$1" "cat >/etc/systemd/system/lab-route.service <<'EOF'
[Unit]
Description=Lab route to the devices
After=network.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/sbin/ip route replace $NAS_NET4 via ${IP[rtr1]}
ExecStart=/sbin/ip -6 route replace $NAS_NET6 via ${IP6[rtr1]}
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now lab-route 2>/dev/null"
}
# The routers: rtr1 peers with all three servers and prefers West, then
# East1, then East2; rtr2 with West only.
router_conf() {
    local name=$1; shift
    local -A pref=([west]=300 [east1]=200 [east1b]=200 [east2]=100)
    local n a af
    printf 'frr defaults traditional\nhostname %s\nlog syslog informational\n!\n' "$name"
    printf 'ip prefix-list RADIUS-ANYCAST seq 10 permit %s/32\nipv6 prefix-list RADIUS-ANYCAST seq 10 permit %s/128\n!\n' "$ANY4" "$ANY6"
    printf 'ip route %s/32 reject 250\nipv6 route %s/128 reject 250\n!\n' "$ANY4" "$ANY6"
    for n in "$@"; do
        printf 'route-map FROM-%s permit 10\n match ip address prefix-list RADIUS-ANYCAST\n set local-preference %s\nexit\n' "${n^^}" "${pref[$n]}"
        printf 'route-map FROM-%s permit 20\n match ipv6 address prefix-list RADIUS-ANYCAST\n set local-preference %s\nexit\n' "${n^^}" "${pref[$n]}"
    done
    printf 'route-map NOTHING deny 10\nexit\n!\nrouter bgp 64500\n bgp router-id %s\n no bgp default ipv4-unicast\n' "${IP[$name]}"
    for n in "$@"; do
        for a in "${IP[$n]}" "${IP6[$n]}"; do printf ' neighbor %s remote-as 65053\n neighbor %s bfd\n' "$a" "$a"; done
    done
    for af in ipv4 ipv6; do
        printf ' address-family %s unicast\n' "$af"
        for n in "$@"; do
            if [[ $af == ipv4 ]]; then a=${IP[$n]}; else a=${IP6[$n]}; fi
            printf '  neighbor %s activate\n  neighbor %s route-map FROM-%s in\n  neighbor %s route-map NOTHING out\n  neighbor %s maximum-prefix 1\n' \
                "$a" "$a" "${n^^}" "$a" "$a"
        done
        printf ' exit-address-family\n'
    done
    printf 'exit\n'
}
# lab_machines: the three servers (fresh), the routers and the device,
# with their routes; FRR on the routers.
lab_machines() {
    local n
    for n in "${SITES[@]}"; do server "$n" || exit 1; done
    for n in rtr1 rtr2; do
        docker run -d --name "yk-tk-$n" --hostname "$n" --network yk-tk --ip "${IP[$n]}" --ip6 "${IP6[$n]}" \
            --sysctl net.ipv4.ip_forward=1 --sysctl net.ipv6.conf.all.forwarding=1 \
            --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt apparmor=unconfined --cgroupns private \
            --tmpfs /run --tmpfs /run/lock --stop-signal SIGRTMIN+3 \
            "$image" sh -c 'mount -o remount,rw /sys/fs/cgroup && exec /lib/systemd/systemd' >/dev/null || exit 1
    done
    docker network connect --ip 172.31.100.2 --ip6 fd53:100::2 yk-tk-nas yk-tk-rtr1 || exit 1
    docker run -d --name yk-tk-nas --hostname nas --network yk-tk-nas --ip "$NAS4" --ip6 "$NAS6" --cap-add NET_ADMIN "${names[@]}" \
        -v "$root:/repo:ro" -v yk-tk-lab:/lab:ro "$image" sleep infinity >/dev/null || exit 1
    for n in "${SITES[@]}" rtr1 rtr2; do booted "$n" || exit 1; done
    for n in "${SITES[@]}"; do lab_route "$n" || exit 1; done
    on nas "ip route replace $ANY4/32 via 172.31.100.2 && ip -6 route replace $ANY6/128 via fd53:100::2 \
            && ip route replace 172.31.99.0/24 via 172.31.100.2 && ip -6 route replace fd53:99::/64 via fd53:100::2" || exit 1
    router_conf rtr1 east1 east2 west | docker exec -i yk-tk-rtr1 bash -c 'cat >/etc/frr/frr.conf' || exit 1
    router_conf rtr2 west | docker exec -i yk-tk-rtr2 bash -c 'cat >/etc/frr/frr.conf' || exit 1
    for n in rtr1 rtr2; do
        on "$n" "sed -i 's/^bgpd=no/bgpd=yes/; s/^bfdd=no/bfdd=yes/' /etc/frr/daemons && chown frr:frr /etc/frr/frr.conf \
                 && chmod 0640 /etc/frr/frr.conf && systemctl restart frr" || exit 1
    done
}

# routes RTR: the sites whose anycast routes RTR has, IPv4 then IPv6, the one
# it uses first ("west,east1,east2 west,east1,east2"; "-": none).
routes() {
    local names=() n
    for n in "${SITES[@]}"; do names+=("${IP[$n]}=$n" "${IP6[$n]}=$n"); done
    on "$1" "for p in 'ipv4 $ANY4/32' 'ipv6 $ANY6/128'; do
        vtysh -c \"show bgp \${p% *} unicast \${p#* } json\" | python3 -c '
import json, sys
names = dict(a.split(\"=\") for a in sys.argv[1:])
paths = sorted(json.load(sys.stdin).get(\"paths\", []),
               key=lambda p: (not p.get(\"bestpath\", {}).get(\"overall\", False), -p.get(\"locPrf\", 0)))
print(\",\".join(names.get(p.get(\"peer\", {}).get(\"peerId\"), \"?\") for p in paths) or \"-\")' ${names[*]}
    done | paste -sd' '"
}
# sessions NAME: "BGP N, BFD M", the sessions up.
sessions() {
    on "$1" "vtysh -c 'show bgp summary json' | python3 -c '
import json, sys
print(sum(p.get(\"state\") == \"Established\" for af in json.load(sys.stdin).values() for p in af.get(\"peers\", {}).values()))' \
        | sed 's/^/BGP /'; vtysh -c 'show bfd peers json' | python3 -c '
import json, sys
print(sum(p.get(\"status\") == \"up\" for p in json.load(sys.stdin)))' | sed 's/^/BFD /'" | paste -sd, | sed 's/,/, /'
}

echo

# members [SERVER]: each member's role, from East1's patronictl (or
# SERVER's).
members() {
    on "${1:-east1}" "patronictl -c /etc/patroni/18-main.yml list -f json | python3 -c '
import json, sys
s = {(\"Leader\", \"running\"): \"leader\", (\"Quorum Standby\", \"streaming\"): \"quorum\"}
print(\" \".join(\"%s=%s\" % (m[\"Member\"], s.get((m[\"Role\"], m[\"State\"]), m[\"Role\"] + \"/\" + m[\"State\"]))
               for m in sorted(json.load(sys.stdin), key=lambda m: m[\"Member\"])))'"
}
# leader_now: the primary, as West's patronictl lists it.
leader_now() { members west | tr ' ' '\n' | sed -n 's/=leader$//p'; }
# switchover NAME: move the primary to NAME, again until it has it
# (Patroni refuses a standby that isn't one of the synchronous ones yet).
switchover() {
    local _
    for _ in 1 2 3 4 5 6; do
        on "$1" "patronictl -c /etc/patroni/18-main.yml switchover --candidate $1 --force >/dev/null 2>&1"
        [[ $(until_eq 15 "$1" leader_now) == "$1" ]] && return 0
    done
    return 1
}
# since NAME UNIT: when UNIT last started on NAME (seconds since 1970).
since() { on "$1" "systemctl show -P ActiveEnterTimestamp --timestamp=unix $2 | tr -d @"; }

# admin COMMAND: yubikey-db.sh COMMAND on the admins' machine, with the
# files from out/admin.
admin() { docker exec -i yk-tk-nas bash -c ". /lab/out/admin/pg.env && bash /repo/yubikey-db.sh $1"; }

# otp PUBLIC_ID PRIVATE_ID: the YubiKey's next OTP, in OTP (each with a usage
# counter one higher than the last).
c=0 OTP=''
otp() { c=$((c + 1)); OTP=$(on nas "/repo/tests/make-otp.sh $1 $2 $K1 $c 0"); }

# radius SERVER SECRET USER PASSWORD: ACCEPT or REJECT, and where from.
radius() {
    on nas "out=\$(perl /opt/radiator/radiator/radpwtst -s $1 -secret '$2' -auth_port 1812 -noacct -timeout 3 -retries 0 \
                 -trace 4 -user '$3' -password '$4' 2>&1)
            from=\$(grep -o 'Received from [^ ]*' <<<\"\$out\" | head -1 | cut -d' ' -f3)
            if grep -q '^OK' <<<\"\$out\"; then echo \"ACCEPT from \$from\"; elif grep -q 'No reply' <<<\"\$out\"; then echo 'NO REPLY'; else echo \"REJECT from \$from\"; fi"
}
tac() { on nas "perl /repo/tests/radiator/tacacs.pl $1 '$2' $3 ${*:4}"; }

# probe_start: from the device, a TACACS+ login at the anycast address
# every second (svc.backup, in group backup, which has access to core),
# until probe_stop LABEL SECONDS, which checks that no stretch without a
# login lasted more than SECONDS, and shows the logins that failed.
# (CORE_KEY: the device's TACACS+ key.)
probe_start() {
    on nas 'echo run >/tmp/probe.state && : >/tmp/probe.log' || exit 1
    docker exec -d yk-tk-nas bash -c "while [ \"\$(cat /tmp/probe.state)\" = run ]; do
            r=\$(timeout 8 perl /repo/tests/radiator/tacacs.pl $ANY4 '$CORE_KEY' $NAS4 authen svc.backup backup-password-1234 2>&1 | head -1)
            echo \"\$(date +%s) \${r:-NONE}\" >>/tmp/probe.log
            sleep 1
        done" || exit 1
}
probe_stop() {
    local gap
    on nas 'echo stop >/tmp/probe.state'
    sleep 2
    gap=$(on nas "awk '{ if (\$2 == \"PASS\") { if (start) { g = \$1 - start; if (g > max) max = g; start = 0 } }
                        else { bad++; if (!start) start = \$1 } }
                  END { printf \"%d logins, %d failed, the longest gap %d s\\n\", NR, bad, max }' /tmp/probe.log")
    if [[ $gap =~ gap\ ([0-9]+)\ s$ ]] && ((BASH_REMATCH[1] <= $2)); then
        check "$1: at most $2 s without one" "$gap" "$gap"
    else
        check "$1: at most $2 s without one" "at most $2 s" "$gap"
    fi
    on nas "grep -v ' PASS\$' /tmp/probe.log | head -20"
}
