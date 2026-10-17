#!/usr/bin/env bash
#
# turnkey.sh - Test yubikey-turnkey the way its runbook says to use it: make
# the folders from a site.toml, copy each to a fresh Ubuntu 26.04 server
# (systemd, and nothing else installed), run setup.sh on the three at the
# same time, and check what they set up, from a device and from the
# routers.
#
# Usage: tests/radiator/turnkey.sh IMAGE DIR
#   IMAGE  the test image that run.sh builds: it runs the generator (as the
#          admins' machine), the routers (FRR) and the device
#   DIR    the Radiator packages, as for run.sh
#
# The lab, on the Docker network yk-tk (172.31.99.0/24, fd53:99::/64):
#   yk-tk-east1  .11  the usual primary         router: rtr1
#   yk-tk-east2  .12                            router: rtr1
#   yk-tk-west   .13  the last resort           routers: rtr1 and rtr2
#   yk-tk-rtr1   .2   FRR, preferring West, then East1, then East2; also on
#                     yk-tk-nas (172.31.100.0/24, fd53:100::/64) as .2
#   yk-tk-rtr2   .3   FRR, West's second router
#   yk-tk-nas    172.31.100.10 on yk-tk-nas: a device in device group core,
#                     and the admins' machine (the admin subnet)
# The servers start from the image yk-turnkey-base:26.04 (ubuntu:26.04 with
# systemd and iproute2), so setup.sh installs everything with apt-get (this
# needs network access); the packages come from yubikey-turnkey --packages.
#
# Checks: the generator's output and --check; setup.sh --check; setup.sh on
# the three at once; the cluster, the anycast check and the BGP sessions;
# logins at the anycast addresses over RADIUS and TACACS+, IPv4 and IPv6,
# as a YubiKey user and a service account, refused for a group without
# access to the device's group and from an unknown device (the catch-all);
# West withdrawn from both of its routers when only its TACACS+ login
# fails, and when its check stops; setup.sh --status, when all is well and
# when etcd, a router, the primary, the anycast check or the folder isn't;
# the backups (setup.sh's first, the daily ones on a standby, how many it
# keeps, --status when one is old or the timer is off, a check on the
# admin's machine, a restore on the primary: what it undoes, the counters
# and the anycast checks' keys it keeps, and a refusal on a standby); the
# firewall; setup.sh run again (nothing changes or restarts); a reboot; a
# new device from site.toml; new certificates; --reset on all three, then
# the last backup restored into the new cluster.
#
# Needs Docker, usable without sudo. KEEP=1 leaves the containers running.
# Exits 0 when every check passes.

# shellcheck disable=SC2016  # the containers' shells expand the commands given to "on"

set -uo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
root=$(dirname -- "$(dirname -- "$here")")
[[ $# -eq 2 && -d $2 ]] || { echo "usage: tests/radiator/turnkey.sh IMAGE DIR" >&2; exit 2; }
image=$1
rads=$(cd -- "$2" && pwd)
pass=0 fail=0
SITES=(east1 east2 west)
BASE=yk-turnkey-base:26.04
declare -A IP=([east1]=172.31.99.11 [east2]=172.31.99.12 [west]=172.31.99.13 [rtr1]=172.31.99.2 [rtr2]=172.31.99.3)
declare -A IP6=([east1]=fd53:99::11 [east2]=fd53:99::12 [west]=fd53:99::13 [rtr1]=fd53:99::2 [rtr2]=fd53:99::3)
NAS4=172.31.100.10 NAS6=fd53:100::10 NAS_NET4=172.31.100.0/24 NAS_NET6=fd53:100::/64
ANY4=192.0.2.153 ANY6=2001:db8:153::153
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
DOMAIN=tk.test

remove_lab() {
    docker rm -f yk-tk-east1 yk-tk-east2 yk-tk-west yk-tk-rtr1 yk-tk-rtr2 yk-tk-nas >/dev/null 2>&1
    docker network rm yk-tk yk-tk-nas >/dev/null 2>&1
    docker volume rm yk-tk-lab >/dev/null 2>&1
}
remove_lab
if [[ ${KEEP-} == 1 ]]; then
    trap 'echo "KEEP=1: the containers are still running"' EXIT
else
    trap remove_lab EXIT
fi

# check LABEL EXPECTED ACTUAL: count and print one result.
check() {
    if [[ $3 == "$2" ]]; then
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# check_match LABEL REGEX ACTUAL
check_match() {
    if [[ $3 =~ $2 ]]; then
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$3"
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

# The admins' machine: the packages, and site.toml.
lab() { docker run --rm -v "$root:/repo:ro" -v "$rads:/radiator:ro" -v yk-tk-lab:/lab "$image" bash -c "$1"; }
lab 'mkdir -p /lab/pkgs && /repo/packaging/build-deb.sh /lab/pkgs >/dev/null && cp /radiator/*.deb /lab/pkgs/' || exit 1
# The backups' key pair, as the guide makes it (with the passphrase given
# here instead of asked).
lab 'cd /lab && openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -aes-256-cbc -pass pass:lab-only -out backup.key \
     && openssl req -new -x509 -key backup.key -passin pass:lab-only -days 7300 -subj "/CN=yubikey backups" -out backup.crt' \
    || exit 1
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
site_toml '' | docker run --rm -i -v yk-tk-lab:/lab "$image" bash -c 'cat >/lab/site.toml' || exit 1
gen() { lab "cd /lab && python3 /repo/yubikey-turnkey $1 2>&1"; }

echo "== The generator"
out=$(gen '-p /lab/pkgs site.toml'); rc=$?
check "yubikey-turnkey makes the folders" 0 "$rc"
[[ $rc == 0 ]] || { printf '%s\n' "$out"; exit 1; }
check "secrets.toml is the admin's only" 600 "$(lab 'stat -c %a /lab/secrets.toml')"
check "out/ is the admin's only" 700 "$(lab 'stat -c %a /lab/out')"
check "a server's folder has setup.sh and the packages" \
    "install.sh radiator radiator-radius-utilxs radiator-yubikey setup.sh" \
    "$(lab 'cd /lab/out/west && ls *.deb install.sh setup.sh | sed "s/_.*//" | sort -u | paste -sd" "')"
check "--check: up to date" "0 up to date" \
    "$(lab 'cd /lab && python3 /repo/yubikey-turnkey --check -p /lab/pkgs site.toml >/tmp/o; echo $? $(sed "s/.*: //" /tmp/o)')"
check "the same input gives the same output" "out: up to date" "$(gen '-p /lab/pkgs site.toml')"

# secret PATH: a value from secrets.toml, such as device.172.31.100.10.secret.
secret() {
    lab "python3 -c 'import sys, tomllib
d = tomllib.load(open(\"/lab/secrets.toml\", \"rb\"))
for k in sys.argv[1].split(\"|\"): d = d[k]
print(d)' '$1'"
}
CORE_SECRET=$(secret "device|$NAS4|secret") CORE_KEY=$(secret "device|$NAS4|tacacs_key")
CORE6_SECRET=$(secret "device|$NAS6|secret") CORE6_KEY=$(secret "device|$NAS6|tacacs_key")
CATCH_KEY=$(secret 'catch_all|tacacs_key')

# SIGRTMIN+3 makes systemd shut down cleanly, so 'docker restart' is a clean
# reboot. The servers may bind to addresses they don't have (Docker mounts
# /proc/sys read-only, so setup.sh can't set this itself; it checks it).
# Docker writes /etc/hosts anew at each start, without setup.sh's lines: it
# gets the servers' names too, as DNS would.
names=(--add-host "east1.$DOMAIN:${IP[east1]}" --add-host "east2.$DOMAIN:${IP[east2]}" --add-host "west.$DOMAIN:${IP[west]}")
for n in "${SITES[@]}"; do
    docker run -d --name "yk-tk-$n" --hostname "$n" --network yk-tk --ip "${IP[$n]}" --ip6 "${IP6[$n]}" "${names[@]}" \
        --sysctl net.ipv4.ip_nonlocal_bind=1 --sysctl net.ipv6.ip_nonlocal_bind=1 \
        --cap-add SYS_ADMIN --cap-add NET_ADMIN --security-opt apparmor=unconfined --cgroupns private \
        --tmpfs /run --tmpfs /run/lock --stop-signal SIGRTMIN+3 -v yk-tk-lab:/lab:ro \
        "$BASE" sh -c 'mount -o remount,rw /sys/fs/cgroup && exec /lib/systemd/systemd' >/dev/null || exit 1
done
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

# The network around the servers: their routes to the device's network
# through rtr1, kept across reboots (the lab's, not setup.sh's job).
for n in "${SITES[@]}"; do
    on "$n" "cat >/etc/systemd/system/lab-route.service <<'EOF'
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
systemctl daemon-reload && systemctl enable --now lab-route 2>/dev/null" || exit 1
done
on nas "ip route replace $ANY4/32 via 172.31.100.2 && ip -6 route replace $ANY6/128 via fd53:100::2 \
        && ip route replace 172.31.99.0/24 via 172.31.100.2 && ip -6 route replace fd53:99::/64 via fd53:100::2" || exit 1

# The routers: rtr1 peers with all three servers and prefers West, then
# East1, then East2; rtr2 with West only.
router_conf() {
    local name=$1; shift
    local -A pref=([west]=300 [east1]=200 [east2]=100)
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
router_conf rtr1 east1 east2 west | docker exec -i yk-tk-rtr1 bash -c 'cat >/etc/frr/frr.conf' || exit 1
router_conf rtr2 west | docker exec -i yk-tk-rtr2 bash -c 'cat >/etc/frr/frr.conf' || exit 1
for n in rtr1 rtr2; do
    on "$n" "sed -i 's/^bgpd=no/bgpd=yes/; s/^bfdd=no/bfdd=yes/' /etc/frr/daemons && chown frr:frr /etc/frr/frr.conf \
             && chmod 0640 /etc/frr/frr.conf && systemctl restart frr" || exit 1
done

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
echo "== setup.sh"
for n in "${SITES[@]}"; do on "$n" "cp -a /lab/out/$n /root/turnkey && chmod 700 /root/turnkey" || exit 1; done
for n in "${SITES[@]}"; do
    out=$(on "$n" '/root/turnkey/setup.sh --check'); rc=$?
    check "$n: setup.sh --check on a fresh server" "0 Nothing to fix." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
done
work=$(mktemp -d)
start=$SECONDS
for n in "${SITES[@]}"; do
    on "$n" '/root/turnkey/setup.sh' >"$work/$n.log" 2>&1 &
    echo $! >"$work/$n.pid"
done
for n in "${SITES[@]}"; do
    wait "$(cat "$work/$n.pid")"; rc=$?
    check "$n: setup.sh" "0 $n is set up." "$rc $(tail -1 "$work/$n.log")"
    if [[ $rc != 0 ]]; then echo "--- $n's setup.sh:"; cat "$work/$n.log"; fi
done
echo "(the three setup.sh took $((SECONDS - start)) s)"
for n in "${SITES[@]}"; do sed -n '/== report/,$p' "$work/$n.log" | sed "s/^/$n: /"; done

check "west: /etc/hosts has the three servers, IPv4 only" \
    "${IP[east1]} east1.$DOMAIN east1|${IP[east2]} east2.$DOMAIN east2|${IP[west]} west.$DOMAIN west" \
    "$(on west 'sed -n "/^# BEGIN yubikey-turnkey/,/^# END/{/^#/d;p}" /etc/hosts' | tr '\t' ' ' | paste -sd'|')"
check "and the host name no other address" "" "$(on west 'grep -v "^#" /etc/hosts | grep -wn west | grep -v "${IP[west]}"')"

echo
echo "== The cluster and the anycast check"
# members: each member's role, from East1's patronictl.
members() {
    on east1 "patronictl -c /etc/patroni/18-main.yml list -f json | python3 -c '
import json, sys
s = {(\"Leader\", \"running\"): \"leader\", (\"Quorum Standby\", \"streaming\"): \"quorum\"}
print(\" \".join(\"%s=%s\" % (m[\"Member\"], s.get((m[\"Role\"], m[\"State\"]), m[\"Role\"] + \"/\" + m[\"State\"]))
               for m in sorted(json.load(sys.stdin), key=lambda m: m[\"Member\"])))'"
}
check "Patroni: East1 leads, the others confirm its commits" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 30 "east1=leader east2=quorum west=quorum" members)"
for n in "${SITES[@]}"; do
    check "$n: the anycast check advertises" advertised \
        "$(until_eq 30 advertised on "$n" '/opt/radiator-yubikey/yubikey-anycast.sh status | head -1 | cut -d" " -f1')"
    check_match "$n: its last check logged in over RADIUS and TACACS+" '^ACCEPT in [0-9]+ ms; TACACS\+ PASS in [0-9]+ ms' \
        "$(on "$n" '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
    check "$n: partition mode, normal" "normal" \
        "$(on "$n" '/opt/radiator-yubikey/yubikey-partition.sh status | head -1 | cut -d" " -f1')"
done
check "rtr1: the routes of all three, West first" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
check "rtr2 (West's second router): West's routes" "west west" "$(until_eq 30 "west west" routes rtr2)"
check "rtr1: BGP and BFD with the three servers, IPv4 and IPv6" "BGP 6, BFD 6" "$(until_eq 30 "BGP 6, BFD 6" sessions rtr1)"
check "west: BGP sessions with both routers" "BGP 4, BFD 4" "$(until_eq 30 "BGP 4, BFD 4" sessions west)"

echo
echo "== setup.sh --status"
for n in "${SITES[@]}"; do check_status "$n: --status: all is well" "$n" "^0 $n: OK\$"; done
on east1 'cat /tmp/status.out' | sed 's/^/east1: /'
echo "(east1's --status took $(on east1 's=$(date +%s%N); /root/turnkey/setup.sh --status >/dev/null; echo $((($(date +%s%N) - s) / 1000000))') ms)"
check "every line ok" 0 "$(on east1 'tail -n +3 /tmp/status.out | grep -cv "^  ok    "')"
check "west: the package's copy, without the folder" "0 west: OK" \
    "$(on west 'mv /root/turnkey /root/turnkey.away
                /opt/radiator-yubikey/yubikey-turnkey-setup.sh --status >/tmp/status.out 2>&1; echo "$? $(head -1 /tmp/status.out)"
                mv /root/turnkey.away /root/turnkey')"
check "not as root: UNKNOWN" "3 UNKNOWN - run it as root (sudo /opt/radiator-yubikey/yubikey-turnkey-setup.sh --status)" \
    "$(on west 'out=$(runuser -u nobody -- /opt/radiator-yubikey/yubikey-turnkey-setup.sh --status); echo "$? $out"')"

echo
echo "== Logins at the anycast addresses"
# The admin, from the device's machine (in the admin subnet), with the files
# from out/admin.
on nas 'cp /lab/out/admin/ca.crt /root/.yubikey-ca.crt && install -m 0600 /lab/out/admin/pgpass /root/.pgpass' || exit 1
admin() { docker exec -i yk-tk-nas bash -c ". /lab/out/admin/pg.env && bash /repo/yubikey-db.sh $1"; }
out=$(admin "import - <<'EOF'
alice,vvccccbbcdef,4a6f8e2d1c3b,$K1,s3cr3t,1
bob,vvccccbbcdeg,4a6f8e2d1c3c,$K1,s3cr3t,1
EOF
") || printf '%s\n' "$out"
check "the admin loads YubiKeys over TLS, from the admin subnet" "Imported 2 row(s)" "$(grep -o 'Imported 2 row(s)' <<<"$out")"
printf '%s\n' 'backup-password-1234' | admin 'service add svc.backup' >/dev/null 2>&1
for a in 'member add netadmins alice' 'member add helpdesk bob' 'group add backup' 'member add backup svc.backup' \
         'access set backup core 15'; do
    admin "$a" >/dev/null 2>&1 </dev/null
done
# otp PUBLIC_ID PRIVATE_ID: the YubiKey's next OTP, in OTP (each with a usage
# counter one higher than the last).
c=0 OTP=''
otp() { c=$((c + 1)); OTP=$(on nas "/repo/tests/make-otp.sh $1 $2 $K1 $c 0"); }
ALICE=(vvccccbbcdef 4a6f8e2d1c3b) BOB=(vvccccbbcdeg 4a6f8e2d1c3c)
# radius SERVER SECRET USER PASSWORD: ACCEPT or REJECT, and where from.
radius() {
    on nas "out=\$(perl /opt/radiator/radiator/radpwtst -s $1 -secret '$2' -auth_port 1812 -noacct -timeout 3 -retries 0 \
                 -trace 4 -user '$3' -password '$4' 2>&1)
            from=\$(grep -o 'Received from [^ ]*' <<<\"\$out\" | head -1 | cut -d' ' -f3)
            if grep -q '^OK' <<<\"\$out\"; then echo \"ACCEPT from \$from\"; elif grep -q 'No reply' <<<\"\$out\"; then echo 'NO REPLY'; else echo \"REJECT from \$from\"; fi"
}
tac() { on nas "perl /repo/tests/radiator/tacacs.pl $1 '$2' $3 ${*:4}"; }
otp "${ALICE[@]}"
check "RADIUS over IPv4: alice (netadmins) on a core device" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
otp "${ALICE[@]}"
check "RADIUS over IPv6" "ACCEPT from $ANY6" "$(radius "$ANY6" "$CORE6_SECRET" alice "s3cr3t:$OTP")"
otp "${ALICE[@]}"
check "TACACS+ over IPv4: alice" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen alice "s3cr3t:$OTP")"
otp "${ALICE[@]}"
check "TACACS+ over IPv6" PASS "$(tac "$ANY6" "$CORE6_KEY" "$NAS6" authen alice "s3cr3t:$OTP")"
check "TACACS+ authorization: netadmins' level 15" "PASS_ADD priv-lvl=15" \
    "$(tac "$ANY4" "$CORE_KEY" "$NAS4" author alice service=shell,cmd*)"
otp "${BOB[@]}"
check "bob (helpdesk, access devices only) on a core device: RADIUS" "REJECT from $ANY4" \
    "$(radius "$ANY4" "$CORE_SECRET" bob "s3cr3t:$OTP")"
otp "${BOB[@]}"
check "and TACACS+" FAIL "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen bob "s3cr3t:$OTP")"
check "the service account svc.backup over TACACS+" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen svc.backup backup-password-1234)"
check "and over RADIUS" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" svc.backup backup-password-1234)"
on nas 'ip addr add 172.31.100.20/24 dev eth0' || exit 1
check "an unknown device (the catch-all, device group unlisted): no access" FAIL \
    "$(tac "$ANY4" "$CATCH_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"
admin 'access set backup unlisted 1' >/dev/null 2>&1 </dev/null
check "with access to unlisted" PASS "$(tac "$ANY4" "$CATCH_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"
check "the check's user is refused from a device" "REJECT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" anycast-west x:y)"

echo
echo "== Backups"
for n in "${SITES[@]}"; do
    check "$n: setup.sh made the first backup, for the group adm" "640 root:adm" \
        "$(on "$n" 'stat -c "%a %U:%G" /var/backups/yubikey-db.cms.0')"
    check_match "$n: the daily timer, next at about 03:00" '^active .* 03:[0-3][0-9]:[0-9]{2} ' \
        "$(on "$n" 'echo "$(systemctl is-active yubikey-backup.timer) $(systemctl show -P NextElapseUSecRealtime yubikey-backup.timer)"')"
done
check "west: secrets.toml, encrypted, from the folder" same \
    "$(on west 'cmp -s /var/backups/yubikey-turnkey-secrets.toml.cms /lab/out/secrets.toml.cms && echo same')"
for _ in 1 2 3; do on west 'systemctl start yubikey-backup.service'; done
check "west: three more, as the timer makes them: it keeps 3" "yubikey-db.cms.0 yubikey-db.cms.1 yubikey-db.cms.2" \
    "$(on west 'cd /var/backups && ls yubikey-db.cms.* | paste -sd" "')"
check_match "west: from its own PostgreSQL, a standby" '^made /var/backups/yubikey-db\.cms\.0 \([0-9]+ KB, of database yubikey on a standby\); keeping 3$' \
    "$(on west 'journalctl -u yubikey-backup -o cat | grep "^made" | tail -1')"
check_status "west: --status OK" west '^0 west: OK$'
check_match "with its line" '^  ok    backups: the newest backup is 0 min old, 3 of 3 kept$' "$(on west 'grep "backups:" /tmp/status.out')"
on east2 'touch -d "-30 hours" /var/backups/yubikey-db.cms.0'
check_status "east2: the newest 30 hours old: WARNING" east2 \
    '^1 east2: WARNING - backups: the newest backup is 30 h old: none was made in the last 26 hours'
on east2 'systemctl start yubikey-backup.service'
check_status "a new one: OK" east2 '^0 east2: OK$'
on east2 'systemctl stop yubikey-backup.timer'
check_status "the timer stopped: WARNING" east2 '^1 east2: WARNING - backups: the daily timer is off'
on east2 'systemctl start yubikey-backup.timer'
check_status "started: OK" east2 '^0 east2: OK$'

# The admin fetches east1's newest, checks it, and decrypts it on their
# machine, with the key (in /lab); the dump goes to the primary.
on east1 'systemctl start yubikey-backup.service'
fetch() { on "$1" "cat $2" | docker exec -i yk-tk-nas bash -c "cat >$3"; }
put() { on nas "cat $1" | docker exec -i "yk-tk-$2" bash -c "umask 077 && cat >$3"; }
fetch east1 /var/backups/yubikey-db.cms.0 /root/east1.cms
out=$(on nas 'bash /repo/yubikey-backup.sh check --key /lab/backup.key --passin pass:lab-only /root/east1.cms')
check_match "the admin's machine: it decrypts and reads back whole" \
    '^/root/east1\.cms: a whole backup of the YubiKey database, made [0-9-]+ [0-9:]+ UTC \(PostgreSQL 18' "$(head -1 <<<"$out")"
check "with the YubiKeys, the service accounts and the groups" \
    "  it holds 5 YubiKeys (of 5 users), 4 service accounts, 4 groups" "$(tail -1 <<<"$out")"
on nas 'bash /repo/yubikey-backup.sh decrypt --key /lab/backup.key --passin pass:lab-only /root/east1.cms /root/east1.dump >/dev/null' \
    || exit 1
put /root/east1.dump east1 /root/east1.dump
put /root/east1.dump east2 /root/east1.dump
# Since that backup: alice logs in (her counters move ahead), bob's YubiKey
# is deleted, svc.backup leaves the group backup, and West's check renews
# its key.
otp "${ALICE[@]}"
USED=$OTP
check "alice logs in after the backup" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$USED")"
admin 'delete bob vvccccbbcdeg' >/dev/null 2>&1 </dev/null
admin 'member delete backup svc.backup' >/dev/null 2>&1 </dev/null
check_match "west's check renews its key" '^renewed the key of anycast-west' \
    "$(on west 'systemctl stop yubikey-anycast && /opt/radiator-yubikey/yubikey-anycast.sh renew; systemctl start yubikey-anycast')"
check "east2, a standby: no restore there" \
    "3 yubikey-backup.sh: error: this server's PostgreSQL is a standby: restore on the primary" \
    "$(on east2 'out=$(/opt/radiator-yubikey/yubikey-backup.sh restore --yes /root/east1.dump 2>&1); echo "$? $out"')"
out=$(on east1 '/opt/radiator-yubikey/yubikey-backup.sh restore --yes /root/east1.dump 2>&1'); rc=$?
check "east1, the primary: the restore" 0 "$rc"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check "it says that bob's YubiKey comes back" "  YubiKeys deleted since the backup, which come back: bob vvccccbbcdeg" \
    "$(grep '^  YubiKeys' <<<"$out")"
check "and the group's member" "  Groups changed since the backup, which are put back as they were: backup (members)" \
    "$(grep '^  Groups' <<<"$out")"
check "it keeps alice's counters, and the three checks' keys" \
    "Kept the counters of 1 YubiKey(s) that were ahead, and the keys of 3 anycast check(s)." "$(tail -1 <<<"$out")"
check "alice's OTP from after the backup: still refused" "REJECT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$USED")"
otp "${ALICE[@]}"
check "her next one: accepted" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
check "bob's YubiKey is back" 1 "$(admin 'list bob' 2>/dev/null </dev/null | grep -c vvccccbbcdeg)"
check "svc.backup is in the group backup again" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen svc.backup backup-password-1234)"
sleep 10
check "west's renewed key stays: all three still advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
check_match "west's check logs in" '^ACCEPT in [0-9]+ ms; TACACS\+ PASS' \
    "$(on west '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
check_status "east1: --status OK" east1 '^0 east1: OK$'

echo
echo "== West withdraws when only its TACACS+ login fails, from both routers"
admin 'service disable svc.anycast-west' >/dev/null 2>&1 </dev/null
check "rtr1: West gone" "east1,east2 east1,east2" "$(until_eq 40 "east1,east2 east1,east2" routes rtr1)"
check "rtr2: West gone" "- -" "$(until_eq 10 "- -" routes rtr2)"
check_match "west's check: RADIUS works, TACACS+ refused" '^ACCEPT in [0-9]+ ms; TACACS\+ FAIL in [0-9]+ ms: No such user' \
    "$(on west '/opt/radiator-yubikey/yubikey-anycast.sh status | sed -n "s/^last check: //p"')"
check_status "west: --status: CRITICAL, withdrawn" west '^2 west: CRITICAL - anycast: withdrawn since .*TACACS\+ FAIL'
otp "${ALICE[@]}"
check "RADIUS at the anycast address: East1 answers" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
admin 'service enable svc.anycast-west' >/dev/null 2>&1 </dev/null
check "West back on rtr1" "west,east1,east2 west,east1,east2" "$(until_eq 40 "west,east1,east2 west,east1,east2" routes rtr1)"
check "and on rtr2" "west west" "$(until_eq 10 "west west" routes rtr2)"
on west 'systemctl stop yubikey-anycast'
check "West's check stopped: gone from rtr2 at once" "- -" "$(until_eq 10 "- -" routes rtr2)"
on west 'systemctl start yubikey-anycast'
check "and back" "west west" "$(until_eq 30 "west west" routes rtr2)"

echo
echo "== What --status sees"
on east2 'systemctl stop etcd'
check_status "etcd stopped on east2: east1 warns" east1 '^1 east1: WARNING - etcd: 2 of 3 members healthy \(not east2\)$'
check_status "east2: CRITICAL" east2 '^2 east2: CRITICAL - not running: etcd .*etcd: 2 of 3 members healthy \(not east2\)'
on east2 'systemctl start etcd'
check_status "etcd started: east2 OK" east2 '^0 east2: OK$'
on rtr2 'systemctl stop frr'
check_status "rtr2 stopped: west warns" west '^1 west: WARNING - BGP: .*Established.*(Active|Connect|Idle)'
on rtr2 'systemctl start frr'
check_status "rtr2 back: west OK" west '^0 west: OK$'
on east1 'patronictl -c /etc/patroni/18-main.yml switchover --candidate east2 --force >/dev/null 2>&1'
check "the primary moved to east2" "east1=quorum east2=leader west=quorum" \
    "$(until_eq 60 "east1=quorum east2=leader west=quorum" members)"
check_status "east1 warns: the primary isn't east1" east1 \
    '^1 east1: WARNING - Patroni: the primary is east2, not east1 \(patronictl switchover --candidate east1\)'
on east1 'patronictl -c /etc/patroni/18-main.yml switchover --candidate east1 --force >/dev/null 2>&1'
check "and back to east1" "east1=leader east2=quorum west=quorum" \
    "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check_status "east1: OK" east1 '^0 east1: OK$'

echo
echo "== The firewall"
check "east1: INPUT drops what isn't allowed" "-P INPUT DROP" "$(on east1 'iptables -S INPUT | head -1')"
check "and IPv6" "-P INPUT DROP" "$(on east1 'ip6tables -S INPUT | head -1')"
check "ufw isn't running" "inactive" "$(on east1 'systemctl is-active ufw')"
check "PostgreSQL from outside the admin subnet (rtr2): no answer" "timeout" \
    "$(on rtr2 "timeout 3 bash -c 'exec 3<>/dev/tcp/${IP[east1]}/5432' 2>/dev/null && echo open || { [[ \$? == 124 ]] && echo timeout || echo refused; }")"
check "Patroni's API from the admin subnet" 200 \
    "$(on nas "curl -s -o /dev/null -w '%{http_code}' --cacert /lab/out/admin/ca.crt https://east1.$DOMAIN:8008/primary")"

echo
echo "== setup.sh again"
pid=$(on west 'systemctl show -p MainPID --value radiator')
out=$(on west '/root/turnkey/setup.sh'); rc=$?
check "west: setup.sh again" "0 west is set up." "$rc $(tail -1 <<<"$out")"
check "it changes nothing" "" "$(grep -E '^  \.\.    (installed|updated|removed)' <<<"$out")"
check "and restarts nothing (Radiator's PID)" "$pid" "$(on west 'systemctl show -p MainPID --value radiator')"
out=$(on west '/root/turnkey/setup.sh --check'); rc=$?
check "setup.sh --check on a server it set up" "0 Nothing to fix." "$rc $(tail -1 <<<"$out")"
[[ $rc == 0 ]] || printf '%s\n' "$out"

echo
echo "== A reboot"
docker restart yk-tk-west >/dev/null && booted west
check "west: the firewall is back" "-P INPUT DROP" "$(on west 'iptables -S INPUT | head -1')"
check "Patroni: west streams again" "west=quorum" \
    "$(until_eq 60 west=quorum bash -c "docker exec yk-tk-west patronictl -c /etc/patroni/18-main.yml list -f json | python3 -c '
import json, sys
print(\" \".join(\"%s=%s\" % (m[\"Member\"], \"quorum\" if m[\"Role\"] == \"Quorum Standby\" and m[\"State\"] == \"streaming\" else m[\"Role\"]) for m in json.load(sys.stdin) if m[\"Member\"] == \"west\"))'")"
check "rtr2: West advertises again" "west west" "$(until_eq 60 "west west" routes rtr2)"

echo
echo "== A new device, from site.toml"
site_toml '[[device]]
address = "172.31.100.20"
group = "lab2"' | docker run --rm -i -v yk-tk-lab:/lab "$image" bash -c 'cat >/lab/site.toml' || exit 1
out=$(gen '-p /lab/pkgs site.toml')
check_match "the generator writes the folders again" 'out/east1/: [0-9]+ written' "$out"
check "with the new device's file in each" 3 "$(lab 'ls /lab/out/*/files/etc/radiator/clients.d/lab2.conf | wc -l')"
LAB2_KEY=$(secret 'device|172.31.100.20|tacacs_key')
for n in "${SITES[@]}"; do
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    if [[ $n == west ]]; then
        check "west: --status: the folder isn't set up yet" \
            "1 west: WARNING - setup.sh: /root/turnkey has changed since setup.sh last finished: run it" "$(status west)"
    fi
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh with the new device" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
done
check_status "west: --status: OK again" west '^0 west: OK$'
check "the new device, in device group lab2: no access yet" FAIL \
    "$(tac "$ANY4" "$LAB2_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"
admin 'access set backup lab2 1' >/dev/null 2>&1 </dev/null
check "with access to lab2" PASS "$(tac "$ANY4" "$LAB2_KEY" 172.31.100.20 authen svc.backup backup-password-1234)"

echo
echo "== New certificates, one server at a time"
# served HOST PORT [starttls]: the serial of the certificate a server presents.
served() {
    on nas "openssl s_client -connect $1:$2 ${3:+-starttls $3} -CAfile /lab/out/admin/ca.crt </dev/null 2>/dev/null \
            | openssl x509 -noout -serial"
}
old=$(served "east1.$DOMAIN" 8008)
out=$(gen '--renew-certs -p /lab/pkgs site.toml')
# (In each folder the certificate and key, for etcd and for Patroni, and the
# copy of secrets.toml.)
check_match "the generator makes new ones" "out/east1/: 5 written" "$out"
for n in east2 west east1; do
    on "$n" "cp -a /lab/out/$n/. /root/turnkey/" || exit 1
    out=$(on "$n" '/root/turnkey/setup.sh'); rc=$?
    check "$n: setup.sh with the new certificate" "0 $n is set up." "$rc $(tail -1 <<<"$out")"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
    new=$(on "$n" 'openssl x509 -noout -serial -in /etc/patroni/tls/server.crt')
    # Patroni takes up a reload in its own loop, within 10 s.
    check "$n: Patroni's REST API presents it" "$new" "$(until_eq 30 "$new" served "$n.$DOMAIN" 8008)"
    check "$n: PostgreSQL presents it" "$new" "$(served "$n.$DOMAIN" 5432 postgres)"
    check "$n: etcd presents it" "$new" \
        "$(on "$n" "openssl s_client -connect ${IP[$n]}:2379 -cert /etc/etcd/tls/server.crt -key /etc/etcd/tls/server.key \
                    -CAfile /etc/etcd/tls/ca.crt </dev/null 2>/dev/null | openssl x509 -noout -serial")"
done
check "east1's is a new one" new "$(if [[ $old != "$new" ]]; then echo new; else echo old; fi)"
check "etcd: 3 members healthy" 3 \
    "$(on east1 'etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
                 --endpoints https://'"${IP[east1]}"':2379 endpoint health --cluster 2>&1 | grep -c "is healthy"')"
check "Patroni: as before" "east1=leader east2=quorum west=quorum" "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
otp "${ALICE[@]}"
check "and log users in" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"

echo
echo "== Start over: --reset on all three, then setup.sh again"
for n in "${SITES[@]}"; do
    out=$(on "$n" "/root/turnkey/setup.sh --reset $n"); rc=$?
    check "$n: setup.sh --reset" "0 gone" "$rc $(on "$n" '[[ -e /var/lib/etcd/default || -e /var/lib/postgresql/18/main ]] && echo there || echo gone')"
    [[ $rc == 0 ]] || printf '%s\n' "$out"
done
check "--reset needs the server's name" 1 "$(on west '/root/turnkey/setup.sh --reset east1 >/dev/null 2>&1; echo $?')"
check "rtr1: none advertises" "- -" "$(until_eq 10 "- -" routes rtr1)"
for n in "${SITES[@]}"; do
    on "$n" '/root/turnkey/setup.sh' >"$work/$n.log" 2>&1 &
    echo $! >"$work/$n.pid"
done
for n in "${SITES[@]}"; do
    wait "$(cat "$work/$n.pid")"; rc=$?
    check "$n: setup.sh after --reset" "0 $n is set up." "$rc $(tail -1 "$work/$n.log")"
    if [[ $rc != 0 ]]; then echo "--- $n's setup.sh:"; cat "$work/$n.log"; fi
done
check "Patroni: a new cluster" "east1=leader east2=quorum west=quorum" "$(until_eq 60 "east1=leader east2=quorum west=quorum" members)"
check "rtr1: all three advertise" "west,east1,east2 west,east1,east2" "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
otp "${ALICE[@]}"
check "the database is new: alice's YubiKey isn't in it" "REJECT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"

# As after losing the whole cluster: the last backup, restored into the new
# one. (The backups stayed; setup.sh made no new one, as one was there.)
check "east1: the backups stay after --reset" "yubikey-db.cms.0 yubikey-db.cms.1" \
    "$(on east1 'cd /var/backups && ls yubikey-db.cms.* | paste -sd" "')"
fetch east1 /var/backups/yubikey-db.cms.0 /root/last.cms
on nas 'bash /repo/yubikey-backup.sh decrypt --key /lab/backup.key --passin pass:lab-only /root/last.cms /root/last.dump >/dev/null' \
    || exit 1
put /root/last.dump east1 /root/last.dump
out=$(on east1 '/opt/radiator-yubikey/yubikey-backup.sh restore --yes /root/last.dump 2>&1'); rc=$?
check "east1: the last backup, restored into the new cluster" 0 "$rc"
[[ $rc == 0 ]] || printf '%s\n' "$out"
check_match "the new cluster's anycast keys stay" 'and the keys of 3 anycast check\(s\)\.$' "$(tail -1 <<<"$out")"
otp "${ALICE[@]}"
check "alice logs in again" "ACCEPT from $ANY4" "$(radius "$ANY4" "$CORE_SECRET" alice "s3cr3t:$OTP")"
check "the groups are back: svc.backup over TACACS+" PASS "$(tac "$ANY4" "$CORE_KEY" "$NAS4" authen svc.backup backup-password-1234)"
sleep 10
check "rtr1: all three still advertise" "west,east1,east2 west,east1,east2" \
    "$(until_eq 30 "west,east1,east2 west,east1,east2" routes rtr1)"
for n in "${SITES[@]}"; do check_status "$n: --status OK" "$n" "^0 $n: OK\$"; done

rm -rf -- "$work"
echo
echo "Turnkey: $pass passed, $fail failed"
[[ $fail == 0 ]]
