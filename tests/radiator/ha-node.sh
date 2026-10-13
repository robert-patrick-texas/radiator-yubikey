#!/bin/bash
#
# ha-node.sh - Runs inside the containers that tests/radiator/ha.sh starts,
# as root, with the repository at /repo (read-only) and a shared volume at
# /lab. Each call does one step on one database server or Radiator server,
# following the guide's "Two database servers" section.
#
# Usage: ha-node.sh COMMAND [ARGS]
#   pki                      (db1) a lab CA, and a certificate for db1 and db2
#   db-setup NAME            TLS, network access and replication settings
#   primary-init             (db1) start, create the roles and the database
#   standby NAME PRIMARY     replace this server's data with a copy of
#                            PRIMARY's, and follow PRIMARY as a standby
#   stop-streaming           stop receiving changes from the primary
#   promote | start | stop   pg_ctlcluster 18 main ...
#   role                     primary or standby
#   sql DB QUERY             run QUERY as postgres; print the rows
#   rad-setup HOSTS          the admin's settings (PGHOST=HOSTS) and
#                            Radiator's configuration from 'config'
#   admin ARGS...            yubikey-db.sh ARGS with the admin's settings
#   hold-row SECONDS         lock alice's row, without changing it
#   rad-start                (re)start radiusd
#   login USER PW COUNTER SESSION [TIMEOUT]
#                            log in with radpwtst (waiting up to TIMEOUT
#                            seconds, default 15); prints Radiator's answer
#                            (ACCEPT, NO REPLY, or REJECT: reason) and the
#                            time it took in milliseconds, on two lines

set -euo pipefail

PGCONF=/etc/postgresql/18/main
PGDATA=/var/lib/postgresql/18/main
RAD=/opt/radiator/radiator
LOG=/var/log/radiator/radiator.log
LAB=/lab
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d

cmd=$1; shift
case $cmd in
pki)
    cd "$LAB"
    {
        openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj "/CN=lab CA" -keyout ca.key -out ca.crt
        for h in db1 db2; do
            openssl req -newkey rsa:3072 -nodes -subj "/CN=$h.yk.test" -addext "subjectAltName=DNS:$h.yk.test" \
                -keyout $h.key -out $h.csr
            openssl x509 -req -in $h.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 30 -copy_extensions copy -out $h.crt
        done
    } >/dev/null 2>&1
    ;;

db-setup)
    h=$1
    install -m 0644 -o postgres -g postgres "$LAB/$h.crt" $PGCONF/server.crt
    install -m 0600 -o postgres -g postgres "$LAB/$h.key" $PGCONF/server.key
    cat >$PGCONF/conf.d/yubikey.conf <<'EOF'
listen_addresses = '*'
ssl = on
ssl_cert_file = '/etc/postgresql/18/main/server.crt'
ssl_key_file = '/etc/postgresql/18/main/server.key'
wal_keep_size = '1GB'
EOF
    # The same rules on both servers: either one can be the primary.
    sed -i '0,/^host /s//hostssl  yubikey      radiator    172.31.98.21\/32  scram-sha-256\
hostssl  yubikey      radiator    172.31.98.22\/32  scram-sha-256\
hostssl  yubikey      opsadmin    172.31.98.21\/32  scram-sha-256\
hostssl  replication  replicator  172.31.98.11\/32  scram-sha-256\
hostssl  replication  replicator  172.31.98.12\/32  scram-sha-256\
&/' $PGCONF/pg_hba.conf
    # For when this server is the standby: the CA and the replication password.
    install -d -m 0700 -o postgres -g postgres /var/lib/postgresql/.postgresql
    install -m 0644 -o postgres -g postgres "$LAB/ca.crt" /var/lib/postgresql/.postgresql/root.crt
    touch /var/lib/postgresql/.pgpass
    chown postgres:postgres /var/lib/postgresql/.pgpass
    chmod 0600 /var/lib/postgresql/.pgpass
    echo '*:5432:replication:replicator:lab-repl-pw' | tee /var/lib/postgresql/.pgpass >/dev/null
    # PostgreSQL must not start by itself (no effect here: no systemd).
    echo manual >$PGCONF/start.conf
    ;;

primary-init)
    pg_ctlcluster 18 main start
    runuser -u postgres -- psql -X -q -c "CREATE ROLE replicator REPLICATION LOGIN PASSWORD 'lab-repl-pw'"
    runuser -u postgres -- /repo/yubikey-db.sh -b pg init-pg --admin opsadmin >/dev/null
    runuser -u postgres -- psql -X -q -c "ALTER ROLE radiator PASSWORD 'lab-radiator-pw'" \
        -c "ALTER ROLE opsadmin PASSWORD 'lab-admin-pw'"
    ;;

standby)
    name=$1 primary=$2
    pg_ctlcluster 18 main stop >/dev/null 2>&1 || true
    mv "$PGDATA" "$PGDATA.$(date +%Y%m%d-%H%M%S%N)"
    runuser -u postgres -- pg_basebackup -h "$primary.yk.test" -U replicator -D "$PGDATA" -R -X stream -c fast \
        -d "sslmode=verify-full application_name=$name"
    pg_ctlcluster 18 main start 2>&1 | sed '/^Removed stale pid file/d'
    ;;

stop-streaming)
    runuser -u postgres -- psql -X -q -c "ALTER SYSTEM SET primary_conninfo = ''" -c "SELECT pg_reload_conf()" >/dev/null
    ;;

promote|start|stop)
    pg_ctlcluster 18 main "$cmd" 2>&1 | sed '/^Removed stale pid file/d'
    ;;

role)
    runuser -u postgres -- psql -X -At -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'standby' ELSE 'primary' END"
    ;;

sql)
    runuser -u postgres -- psql -X -At -d "$1" -c "$2"
    ;;

hold-row)
    runuser -u postgres -- psql -X -q -d yubikey -c "BEGIN;
        UPDATE yubikeys SET accessed = accessed WHERE username = 'alice';
        SELECT pg_sleep($1); COMMIT;" >/dev/null
    ;;

rad-setup)
    install -m 0644 "$LAB/ca.crt" /etc/radiator/pg-ca.crt
    printf 'export PGHOST=%s PGUSER=opsadmin PGSSLMODE=verify-full PGSSLROOTCERT=/etc/radiator/pg-ca.crt DB_BACKEND=pg\n' \
        "$1" >/root/pg.env
    printf '*:5432:yubikey:opsadmin:lab-admin-pw\n' >/root/.pgpass
    chmod 0600 /root/.pgpass
    install -m 0640 -o root -g radiator /repo/radiator.example.conf /etc/radiator/radiator.conf
    install -m 0640 -o root -g radiator /dev/null /etc/radiator/conf.d/yubikey.conf
    # shellcheck source=/dev/null
    (. /root/pg.env; /repo/yubikey-db.sh config) \
        | sed 's/^\( *\)DBAuth *$/\1DBAuth       lab-radiator-pw/' >/etc/radiator/conf.d/yubikey.conf
    ;;

admin)
    # shellcheck source=/dev/null
    . /root/pg.env
    /repo/yubikey-db.sh "$@"
    ;;

rad-start)
    pkill -f radiusd || true
    sleep 0.5
    rm -f "$LOG"
    setsid su radiator -s /bin/sh -c \
        "perl $RAD/radiusd -foreground -no_pid_file -trace 4 -config_file /etc/radiator/radiator.conf" \
        </dev/null >/tmp/radiusd.out 2>&1 &
    for _ in $(seq 50); do
        grep -qs 'Server started' "$LOG" && exit 0
        sleep 0.2
    done
    echo "radiusd did not start:"; tail -20 "$LOG" /tmp/radiusd.out
    exit 1
    ;;

login)
    user=$1 pw=$2 counter=$3 session=$4 timeout=${5:-15}
    otp=$(/repo/tests/make-otp.sh vvccccbbcdef 4a6f8e2d1c3b $K1 "$counter" "$session")
    before=$(wc -l <"$LOG")
    start=$(date +%s%N)
    out=$(perl $RAD/radpwtst -s 127.0.0.1 -secret local-test-secret -auth_port 1812 -noacct -timeout "$timeout" \
            -user "$user" -password "$pw:$otp" 2>&1) || true
    ms=$((($(date +%s%N) - start) / 1000000))
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
    echo "ha-node.sh: unknown command '$cmd'" >&2
    exit 2
    ;;
esac
