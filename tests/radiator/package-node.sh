#!/bin/bash
#
# package-node.sh - Runs inside the containers that tests/radiator/package.sh
# starts, as root, with the repository at /repo, the Radiator packages at
# /radiator, and install.sh next to the radiator-yubikey package at /inst
# (all read-only). Each call does one step.
#
# Usage: package-node.sh COMMAND [ARGS]
#   radiator-package     install Radiator Software's packages
#   radiator-inplace     unpack Radiator's source in /opt/radiator/radiator,
#                        with the Perl modules Radiator itself needs
#   radiator-make        unpack Radiator's source in /usr/src/radiator and
#                        install it with 'perl Makefile.PL && make && make
#                        install' (radiusd in /usr/local/bin)
#   radiator-dirs        the directories Radiator's package would make, for
#                        Radiator from source (after the radiator user)
#   radiator-unit        Radiator's goodies/radiator.service in
#                        /etc/systemd/system, as install.sh says
#   login RADIUSD        a database with one user, Radiator (RADIUSD) with
#                        radiator.example.conf and the clause from 'config',
#                        and two logins with the same OTP: prints the two
#                        answers, ACCEPT or REJECT
#   todo-commands        the commands from the "To do" list of 'install.sh
#                        --check', one per line, without sudo
#
# Radiator's source comes from the radiator package, which holds Radiator's
# source distribution (with its Makefile.PL and MANIFEST).

set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

Y=/opt/radiator-yubikey/yubikey-db.sh
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d

# apt PACKAGE...: install with apt-get, quietly.
apt() {
    [[ -n $(find /var/lib/apt/lists -maxdepth 1 -name '*Packages*' -print -quit) ]] || apt-get -qq update
    apt-get install -y -qq "$@" >/dev/null
}

# source_to DIR: Radiator's source from the radiator package, in DIR.
source_to() {
    mkdir -p "$1"
    dpkg-deb --fsys-tarfile /radiator/radiator_*_all.deb \
        | tar -x -C "$1" --strip-components=4 ./opt/radiator/radiator
}

case $1 in

radiator-package)
    apt /radiator/radiator_*_all.deb /radiator/radiator-radius-utilxs_*.deb
    ;;

radiator-inplace)
    apt libnet-ssleay-perl
    source_to /opt/radiator/radiator
    ;;

radiator-make)
    apt libnet-ssleay-perl make
    source_to /usr/src/radiator
    cd /usr/src/radiator
    { perl Makefile.PL && make && make install; } >/tmp/make.log 2>&1 \
        || { tail -20 /tmp/make.log; exit 1; }
    ;;

radiator-dirs)
    install -d /etc/radiator/conf.d
    install -d -o radiator -g radiator /var/log/radiator /var/lib/radiator
    ;;

radiator-unit)
    install -m 0644 /opt/radiator/radiator/goodies/radiator.service /etc/systemd/system/
    ;;

login)
    radiusd=$2
    rad=$(dirname -- "$radiusd")
    for d in /opt/radiator/radiator /usr/src/radiator; do
        if [[ -f $d/dictionary ]]; then dictionary=$d/dictionary; break; fi
    done
    command -v openssl >/dev/null || apt openssl
    "$Y" init --owner radiator:radiator >/dev/null
    printf 'username,public_id,private_id,aes_key,password,active\nalice,vvccccbbcdef,4a6f8e2d1c3b,%s,1234,1\n' "$K1" \
        | "$Y" import - >/dev/null
    sed "s|^DictionaryFile .*|DictionaryFile  $dictionary|" /opt/radiator-yubikey/radiator.example.conf \
        >/etc/radiator/radiator.conf
    chgrp radiator /etc/radiator/radiator.conf
    chmod 0640 /etc/radiator/radiator.conf
    "$Y" config >/etc/radiator/conf.d/yubikey.conf
    rm -f /var/log/radiator/radiator.log
    su radiator -s /bin/sh -c "perl $radiusd -foreground -no_pid_file -config_file /etc/radiator/radiator.conf" \
        >/tmp/radiusd.out 2>&1 &
    for _ in $(seq 50); do
        grep -qs 'Server started' /var/log/radiator/radiator.log && break
        sleep 0.2
    done
    grep -qs 'Server started' /var/log/radiator/radiator.log \
        || { echo "radiusd did not start:"; tail -20 /var/log/radiator/radiator.log /tmp/radiusd.out; exit 1; }
    otp=$(/opt/radiator-yubikey/tests/make-otp.sh vvccccbbcdef 4a6f8e2d1c3b "$K1" 1 0)
    answers=()
    for _ in 1 2; do
        # radpwtst finds the dictionary next to it, but not in /usr/local/bin.
        if perl "$rad/radpwtst" -dictionary "$dictionary" -s 127.0.0.1 -secret local-test-secret \
                -auth_port 1812 -noacct -user alice -password "1234:$otp" 2>&1 | grep -q '^OK'; then
            answers+=(ACCEPT)
        else
            answers+=(REJECT)
        fi
    done
    pkill -u radiator || true
    echo "${answers[*]}"
    ;;

todo-commands)
    bash /inst/install.sh --check | sed -n 's/^      sudo //p'
    ;;

*)
    echo "package-node.sh: unknown command '$1'" >&2
    exit 2
    ;;
esac
