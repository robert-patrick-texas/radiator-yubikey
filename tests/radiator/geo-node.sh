#!/bin/bash
#
# geo-node.sh - Runs inside the containers that tests/radiator/geo.sh starts,
# as root, with systemd running, the repository at /repo (read-only) and a
# shared volume at /lab. Each call does one step on one site's server, which
# runs etcd, PostgreSQL under Patroni, and Radiator, as in the guide's
# "Three sites" section. The server's name (east1, east2 or west) is the
# first part of its hostname.
#
# Usage: geo-node.sh COMMAND [ARGS]
#   pki                      a lab CA, and a certificate for each server
#   wan-install              lab-wan.service, which runs 'wan' at every boot
#   wan                      the WAN delays to the other servers
#   cut PEER... | heal PEER...
#                            drop all packets to PEER, or stop dropping them
#   etcd-setup               replace the package's single-node etcd with this
#                            server's member of the three-member cluster
#   etcd-start               start etcd (returns once two members run)
#   etcdctl ARGS...          etcdctl ARGS, with this server's certificate
#   patroni-setup PRIORITY   drop the package's PostgreSQL cluster; write
#                            /etc/patroni/18-main.yml (failover_priority
#                            PRIORITY); enable patroni@18-main, restarted
#                            if it fails
#   patroni-start            start patroni@18-main
#   db-init                  (on the leader) the yubikey database and roles
#   members                  each member's role, from patronictl:
#                            "east1=leader east2=quorum west=quorum"
#   rtt PEER                 milliseconds for a TCP connection to PEER
#   ctl ARGS...              patronictl ARGS
#   api HOST PATH            the HTTP status of Patroni's REST API on HOST
#   role                     primary or standby (this server's PostgreSQL)
#   sql DB QUERY             run QUERY as postgres; print the rows
#   rad-setup                the admin's settings and Radiator's configuration
#                            from 'config'; enable and start radiator
#   admin ARGS...            yubikey-db.sh ARGS with the admin's settings
#   login USER PW COUNTER SESSION [TIMEOUT]
#                            log in with radpwtst (waiting up to TIMEOUT
#                            seconds, default 15); prints Radiator's answer
#                            (ACCEPT, NO REPLY, or REJECT: reason) and the
#                            milliseconds from request to reply ("-" for no
#                            reply), on two lines

set -euo pipefail

declare -A IP=([east1]=172.31.97.11 [east2]=172.31.97.12 [west]=172.31.97.13)
NODES=(east1 east2 west)
ME=$(hostname -s)
RAD=/opt/radiator/radiator
LOG=/var/log/radiator/radiator.log
LAB=/lab
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
PATRONI=/etc/patroni/18-main.yml

# One-way delay from this server to PEER: 2 ms between the two East sites
# (4 ms round trip), 27.5 ms between West and East (55 ms round trip).
delay() {
    if [[ $ME == east* && $1 == east* ]]; then echo 2ms; else echo 27.5ms; fi
}

# The traffic control band for PEER: one per other server, after the three
# that prio uses for everything else.
band() {
    local i=4 n
    for n in "${NODES[@]}"; do
        [[ $n == "$ME" ]] && continue
        [[ $n == "$1" ]] && { echo $i; return; }
        i=$((i + 1))
    done
    echo "geo-node.sh: unknown server '$1'" >&2
    exit 2
}

cmd=$1; shift
case $cmd in
pki)
    cd "$LAB"
    {
        # Python 3.13 and later (Patroni) insist on the key usage extensions.
        openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj "/CN=lab CA" \
            -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
            -keyout ca.key -out ca.crt
        for n in "${NODES[@]}"; do
            openssl req -newkey rsa:3072 -nodes -subj "/CN=$n.yk.test" \
                -addext "subjectAltName=DNS:$n.yk.test,IP:${IP[$n]}" \
                -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
                -addext "extendedKeyUsage=serverAuth,clientAuth" -keyout "$n.key" -out "$n.csr"
            openssl x509 -req -in "$n.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 \
                -copy_extensions copy -out "$n.crt"
        done
    } >/dev/null 2>&1
    ;;

wan)
    tc qdisc replace dev eth0 root handle 1: prio bands 5
    for n in "${NODES[@]}"; do
        [[ $n == "$ME" ]] && continue
        b=$(band "$n")
        tc qdisc replace dev eth0 parent "1:$b" handle "${b}0:" netem delay "$(delay "$n")"
        tc filter add dev eth0 parent 1: protocol ip prio 1 u32 match ip dst "${IP[$n]}/32" flowid "1:$b"
    done
    ;;

wan-install)
    cat >/etc/systemd/system/lab-wan.service <<'EOF'
[Unit]
Description=Lab WAN delays to the other sites
Before=etcd.service patroni@18-main.service radiator.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash /repo/tests/radiator/geo-node.sh wan

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable --now lab-wan 2>/dev/null
    ;;

cut|heal)
    for n in "$@"; do
        b=$(band "$n")
        if [[ $cmd == cut ]]; then loss=(loss 100%); else loss=(); fi
        tc qdisc change dev eth0 parent "1:$b" handle "${b}0:" netem delay "$(delay "$n")" "${loss[@]}"
    done
    ;;

etcd-setup)
    # The package starts a single-node etcd on localhost; its data must go.
    systemctl stop etcd
    rm -rf /var/lib/etcd/default
    install -d -m 0750 -o root -g etcd /etc/etcd/tls
    install -m 0644 "$LAB/ca.crt" /etc/etcd/tls/ca.crt
    install -m 0644 "$LAB/$ME.crt" /etc/etcd/tls/server.crt
    install -m 0640 -o root -g etcd "$LAB/$ME.key" /etc/etcd/tls/server.key
    cluster=
    for n in "${NODES[@]}"; do cluster+=${cluster:+,}$n=https://${IP[$n]}:2380; done
    cat >/etc/default/etcd <<EOF
ETCD_NAME=$ME
ETCD_DATA_DIR=/var/lib/etcd/default
ETCD_LISTEN_PEER_URLS=https://${IP[$ME]}:2380
ETCD_LISTEN_CLIENT_URLS=https://${IP[$ME]}:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://${IP[$ME]}:2380
ETCD_ADVERTISE_CLIENT_URLS=https://${IP[$ME]}:2379
ETCD_INITIAL_CLUSTER=$cluster
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=yubikey-db
ETCD_CERT_FILE=/etc/etcd/tls/server.crt
ETCD_KEY_FILE=/etc/etcd/tls/server.key
ETCD_TRUSTED_CA_FILE=/etc/etcd/tls/ca.crt
ETCD_CLIENT_CERT_AUTH=true
ETCD_PEER_CERT_FILE=/etc/etcd/tls/server.crt
ETCD_PEER_KEY_FILE=/etc/etcd/tls/server.key
ETCD_PEER_TRUSTED_CA_FILE=/etc/etcd/tls/ca.crt
ETCD_PEER_CLIENT_CERT_AUTH=true
EOF
    ;;

etcd-start)
    systemctl start etcd
    ;;

etcdctl)
    etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
        --endpoints "https://${IP[$ME]}:2379" "$@"
    ;;

patroni-setup)
    priority=$1
    # Patroni creates and runs the cluster from now on, not postgresql@18-main.
    if pg_lsclusters -h | grep -q '^18 main '; then pg_dropcluster --stop 18 main; fi
    install -d -m 0750 -o root -g postgres /etc/patroni/tls
    install -m 0644 "$LAB/ca.crt" /etc/patroni/tls/ca.crt
    install -m 0644 "$LAB/$ME.crt" /etc/patroni/tls/server.crt
    install -m 0640 -o root -g postgres "$LAB/$ME.key" /etc/patroni/tls/server.key
    hba=
    for n in "${NODES[@]}"; do
        hba+="    - hostssl replication replicator ${IP[$n]}/32 scram-sha-256
    - hostssl postgres    rewinder   ${IP[$n]}/32 scram-sha-256
    - hostssl yubikey     radiator   ${IP[$n]}/32 scram-sha-256
    - hostssl yubikey     opsadmin   ${IP[$n]}/32 scram-sha-256
"
    done
    hosts=
    for n in "${NODES[@]}"; do hosts+=${hosts:+,}${IP[$n]}:2379; done
    install -m 0640 -o root -g postgres /dev/null $PATRONI
    cat >$PATRONI <<EOF
# The Debian helper scripts below take the version and cluster from the scope.
scope: 18-main
namespace: /postgresql-common/
name: $ME

restapi:
  listen: ${IP[$ME]}:8008
  connect_address: $ME.yk.test:8008
  certfile: /etc/patroni/tls/server.crt
  keyfile: /etc/patroni/tls/server.key
  cafile: /etc/patroni/tls/ca.crt
  authentication:
    username: patroni
    password: lab-patroni-pw

ctl:
  cacert: /etc/patroni/tls/ca.crt
  certfile: /etc/patroni/tls/server.crt
  keyfile: /etc/patroni/tls/server.key

etcd3:
  hosts: $hosts
  protocol: https
  cacert: /etc/patroni/tls/ca.crt
  cert: /etc/patroni/tls/server.crt
  key: /etc/patroni/tls/server.key

bootstrap:
  method: pg_createcluster
  pg_createcluster:
    command: /usr/share/patroni/pg_createcluster_patroni
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    synchronous_mode: quorum
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        ssl: 'on'
        ssl_cert_file: /etc/patroni/tls/server.crt
        ssl_key_file: /etc/patroni/tls/server.key
        max_slot_wal_keep_size: 8GB

postgresql:
  create_replica_method:
    - pg_clonecluster
  pg_clonecluster:
    command: /usr/share/patroni/pg_clonecluster_patroni
  listen: '*:5432'
  connect_address: $ME.yk.test:5432
  # Patroni's own connections to this server use its socket: TLS with
  # verify-full fails for "localhost".
  use_unix_socket: true
  use_unix_socket_repl: true
  data_dir: /var/lib/postgresql/18/main
  bin_dir: /usr/lib/postgresql/18/bin
  config_dir: /etc/postgresql/18/main
  pgpass: /var/lib/postgresql/18-main.pgpass
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
      password: lab-repl-pw
      sslmode: verify-full
      sslrootcert: /etc/patroni/tls/ca.crt
    rewind:
      username: rewinder
      password: lab-rewind-pw
      sslmode: verify-full
      sslrootcert: /etc/patroni/tls/ca.crt
  parameters:
    unix_socket_directories: /var/run/postgresql
    logging_collector: 'on'
    log_directory: /var/log/postgresql
    log_filename: postgresql-18-main.log
  pg_hba:
    - local   all         all                     peer
    - local   replication replicator              scram-sha-256
$hba
watchdog:
  mode: off

tags:
  failover_priority: $priority
EOF
    # Debian's unit leaves Patroni stopped if it crashes, and PostgreSQL
    # running without it; restart it instead.
    install -d /etc/systemd/system/patroni@18-main.service.d
    printf '[Service]\nRestart=on-failure\n' >/etc/systemd/system/patroni@18-main.service.d/restart.conf
    systemctl daemon-reload
    systemctl enable patroni@18-main 2>/dev/null
    ;;

patroni-start)
    systemctl start patroni@18-main
    ;;

db-init)
    runuser -u postgres -- /repo/yubikey-db.sh -b pg init-pg --admin opsadmin >/dev/null
    runuser -u postgres -- psql -X -q -c "ALTER ROLE radiator PASSWORD 'lab-radiator-pw'" \
        -c "ALTER ROLE opsadmin PASSWORD 'lab-admin-pw'"
    ;;

members)
    # One word per member: leader, quorum (a standby that can confirm
    # commits), replica, or Role/State as patronictl shows them.
    patronictl -c $PATRONI list -f json | python3 -c '
import json, sys
short = {("Leader", "running"): "leader", ("Quorum Standby", "streaming"): "quorum",
         ("Replica", "streaming"): "replica"}
print(" ".join("%s=%s" % (m["Member"], short.get((m["Role"], m["State"]),
                                                 (m["Role"] + "/" + m["State"]).replace(" ", "_")))
               for m in sorted(json.load(sys.stdin), key=lambda m: m["Member"])))'
    ;;

rtt)
    # Milliseconds to open a TCP connection to PEER's PostgreSQL.
    # A refusal (nothing listening yet) takes the same round trip.
    python3 -c 'import socket, sys, time
s = socket.socket(); s.settimeout(5)
t = time.monotonic()
try:
    s.connect((sys.argv[1], 5432))
except ConnectionRefusedError:
    pass
print(round((time.monotonic() - t) * 1000))' "${IP[$1]}"
    ;;

ctl)
    patronictl -c $PATRONI "$@"
    ;;

api)
    # The HTTP status of Patroni's REST API on HOST for PATH.
    curl -s -o /dev/null -w '%{http_code}\n' --cacert /etc/patroni/tls/ca.crt "https://$1.yk.test:8008/$2"
    ;;

role)
    runuser -u postgres -- psql -X -At -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END"
    ;;

sql)
    runuser -u postgres -- psql -X -At -d "$1" -c "$2"
    ;;

rad-setup)
    hosts=
    for n in "${NODES[@]}"; do hosts+=${hosts:+,}$n.yk.test; done
    install -m 0644 "$LAB/ca.crt" /etc/radiator/pg-ca.crt
    printf 'export PGHOST=%s PGUSER=opsadmin PGSSLMODE=verify-full PGSSLROOTCERT=/etc/radiator/pg-ca.crt DB_BACKEND=pg\n' \
        "$hosts" >/root/pg.env
    printf '*:5432:yubikey:opsadmin:lab-admin-pw\n' >/root/.pgpass
    chmod 0600 /root/.pgpass
    install -m 0640 -o root -g radiator /repo/radiator.example.conf /etc/radiator/radiator.conf
    install -m 0640 -o root -g radiator /dev/null /etc/radiator/conf.d/yubikey.conf
    # shellcheck source=/dev/null
    (. /root/pg.env; /repo/yubikey-db.sh config) \
        | sed 's/^\( *\)DBAuth *$/\1DBAuth       lab-radiator-pw/' >/etc/radiator/conf.d/yubikey.conf
    systemctl enable --now radiator 2>/dev/null
    for _ in $(seq 50); do
        grep -qs 'Server started' "$LOG" && exit 0
        sleep 0.2
    done
    echo "radiator did not start:"; tail -20 "$LOG"; journalctl -u radiator --no-pager | tail -20
    exit 1
    ;;

admin)
    # shellcheck source=/dev/null
    . /root/pg.env
    /repo/yubikey-db.sh "$@"
    ;;

login)
    user=$1 pw=$2 counter=$3 session=$4 timeout=${5:-15}
    otp=$(/repo/tests/make-otp.sh vvccccbbcdef 4a6f8e2d1c3b $K1 "$counter" "$session")
    before=$(wc -l <"$LOG")
    out=$(perl $RAD/radpwtst -s 127.0.0.1 -secret local-test-secret -auth_port 1812 -noacct -timeout "$timeout" \
            -trace 4 -log_microseconds -user "$user" -password "$pw:$otp" 2>&1) || true
    # The request and the reply are the first two packet dumps; their time
    # stamps end in "HH:MM:SS YYYY MICROSECONDS".
    ms=$(awk '/DEBUG: Packet dump:/ { split($4, t, ":"); us[++n] = ((t[1] * 60 + t[2]) * 60 + t[3]) * 1000000 + $6 }
              END { if (n >= 2) printf "%d", (us[2] - us[1]) / 1000; else print "-" }' <<<"$out")
    if grep -q '^OK' <<<"$out"; then
        echo ACCEPT
    elif grep -q 'No reply' <<<"$out"; then
        echo "NO REPLY"
    else
        sleep 0.1
        echo "REJECT: $(tail -n +$((before + 1)) "$LOG" \
                        | grep -o 'Access rejected for [^:]*: .*' | head -1 | sed 's/^[^:]*: //')"
    fi
    echo "$ms"
    ;;

*)
    echo "geo-node.sh: unknown command '$cmd'" >&2
    exit 2
    ;;
esac
