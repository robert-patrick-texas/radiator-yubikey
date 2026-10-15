#!/bin/bash
#
# radsec.sh - Runs inside the container that tests/radiator/run.sh builds, with
# the repository at /repo (read-only). Tests RadSec (RADIUS over TLS) on
# Radiator with the <ServerRADSEC> clause from radiator.example.conf, set up
# with the guide's "RadSec" commands: TLS 1.2 and 1.3 with AES-256-GCM only,
# and client certificates neither needed nor checked, and its option in
# comments, mutual TLS.
#
# The server is west.example.com (in /etc/hosts, 127.0.0.1). openssl s_client
# checks what each listener negotiates and what it refuses: TLS versions,
# ciphers, key-exchange groups (X25519MLKEM768 by default), and client
# certificates (none, self-signed, another CA's with and without its chain,
# ours with any name). radsecproxy, as a network device would, carries real
# YubiKey logins over TLS 1.3 and 1.2, from radclient as in the guide and
# from radpwtst. Then many logins over one connection, alone and four at a
# time; Radiator restarting under radsecproxy; the groups with OPENSSL_CONF
# and with TLS_ECDH_Curve; on PostgreSQL, a slow login holding up the others
# on its RadSec connection (but not over UDP); and two configuration
# mistakes.
#
# OTPs come from tests/make-otp.sh.

set -uo pipefail

Y=/repo/yubikey-db.sh
RAD=/opt/radiator/radiator
T=/etc/radiator/tls
LOG=/var/log/radiator/radiator.log
CONF=/etc/radiator/radiator.conf
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
K2=0f1e2d3c4b5a69788796a5b4c3d2e1f0
ADMIN=/root/admin      # the admin machine, with the CA
TESTER=/root/tester    # the guide's test machine
pass=0 fail=0

# check LABEL EXPECTED ACTUAL: count and print one result.
check() {
    if [[ $3 == "$2" ]]; then
        pass=$((pass + 1)); printf 'PASS  %s: %s\n' "$1" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s, got %s\n' "$1" "$2" "$3"
    fi
}

# between LABEL LOW HIGH VALUE: check that VALUE is a number from LOW to HIGH.
between() {
    if [[ $4 =~ ^[0-9]+$ ]] && (($4 >= $2 && $4 <= $3)); then
        pass=$((pass + 1)); printf 'PASS  %s: %s (%s to %s)\n' "$1" "$4" "$2" "$3"
    else
        fail=$((fail + 1)); printf 'FAIL  %s: expected %s to %s, got %s\n' "$1" "$2" "$3" "$4"
    fi
}

otp() { /repo/tests/make-otp.sh "$@"; }
# Not %3N: Ubuntu 26.04's date (uutils 0.10) doesn't zero-pad it.
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }

echo '127.0.0.1 west.example.com radius.example.com' >>/etc/hosts

echo "== Certificates and the RadSec clause, as in the guide"
mkdir -p "$ADMIN" "$TESTER"
cd "$ADMIN" || exit 1
# Step 1, on the admin machine.
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=RadSec CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout radsec-ca.key -out radsec-ca.crt 2>/dev/null
openssl req -newkey rsa:3072 -nodes -subj "/CN=west.example.com" \
        -addext "subjectAltName=DNS:west.example.com,DNS:radius.example.com,IP:192.0.2.153,IP:2001:db8:153::153" \
        -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
        -addext "extendedKeyUsage=serverAuth" -keyout west-radsec.key -out west-radsec.csr 2>/dev/null
openssl x509 -req -in west-radsec.csr -CA radsec-ca.crt -CAkey radsec-ca.key -CAcreateserial -days 1826 \
        -copy_extensions copy -out west-radsec.crt 2>/dev/null
check "the server certificate lasts 1826 days" 1826 \
    "$(( ( $(date -d "$(openssl x509 -in west-radsec.crt -noout -enddate | cut -d= -f2)" +%s) \
         - $(date -d "$(openssl x509 -in west-radsec.crt -noout -startdate | cut -d= -f2)" +%s) ) / 86400 ))"
# Step 1, on the server.
install -d -m 0750 -o root -g radiator /etc/radiator/tls
install -m 0644 west-radsec.crt /etc/radiator/tls/server.crt
install -m 0640 -o root -g radiator west-radsec.key /etc/radiator/tls/server.key
install -m 0644 radsec-ca.crt /etc/radiator/tls/ca.crt

# Certificates for the test only: an ECDSA server certificate; clients with
# our CA's certificates, another CA's (straight from its root, or from an
# intermediate), and one self-signed.
# mkcert NAME CN EKU CA [ec]: a certificate signed by CA.CRT.
mkcert() {
    local -a key=(-newkey rsa:3072) ku=digitalSignature,keyEncipherment
    if [[ ${5-} == ec ]]; then key=(-newkey ec -pkeyopt ec_paramgen_curve:P-384); ku=digitalSignature; fi
    openssl req -x509 -new "${key[@]}" -nodes -days 30 -subj "/CN=$2" -CA "$4.crt" -CAkey "$4.key" \
        -addext "basicConstraints=critical,CA:FALSE" -addext "keyUsage=critical,$ku" \
        -addext "subjectAltName=DNS:$2" -addext "extendedKeyUsage=$3" -keyout "$1.key" -out "$1.crt" 2>/dev/null
}
# mkca NAME CN [PARENT]: a CA, or an intermediate CA signed by PARENT.
mkca() {
    local -a by=()
    [[ -n ${3-} ]] && by=(-CA "$3.crt" -CAkey "$3.key")
    openssl req -x509 -new -newkey rsa:3072 -nodes -days 30 -subj "/CN=$2" "${by[@]}" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout "$1.key" -out "$1.crt" 2>/dev/null
}
mkcert server-ec west.example.com serverAuth radsec-ca ec
mkcert nas1     nas1.example.com   clientAuth radsec-ca
mkcert laptop   laptop.example.com clientAuth radsec-ca
mkca other-ca "Some other CA"
mkca other-int "Some other intermediate CA" other-ca
mkcert other    nas1.example.com   clientAuth other-ca
mkcert other2   switch2.example.net clientAuth other-int
openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj "/CN=switch7.example.net" \
        -keyout selfsigned.key -out selfsigned.crt 2>/dev/null
install -m 0640 -o root -g radiator server-ec.key $T/server-ec.key
install -m 0644 server-ec.crt $T/server-ec.crt
cat radsec-ca.crt other-ca.crt >$T/ca-bundle.crt
cd / || exit 1

"$Y" init --owner radiator:radiator >/dev/null 2>&1
"$Y" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $K1 -w s3cr3t >/dev/null
"$Y" add -u bob   -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $K2 -w b0bpin >/dev/null
"$Y" add -u carol -P vvccccbbcdbb -p 4a6f8e2d1c60 -k $K1 -w c4rol >/dev/null
"$Y" add -u dave  -P vvccccbbcdbc -p 4a6f8e2d1c61 -k $K2 -w d4ve >/dev/null
"$Y" config >/etc/radiator/conf.d/yubikey.conf
install -m 0640 -o root -g radiator /repo/radiator.example.conf $CONF
# Step 2: turn the clause on (port 2083).
sed -i '/^#<ServerRADSEC>/,/^#<\/ServerRADSEC>/s/^#//' /etc/radiator/radiator.conf
check "the clause is on" 1 "$(grep -c '^<ServerRADSEC>' $CONF)"

# More listeners for the test, made from the same clause: 2084 with mutual
# TLS (the option in its comments), 2085 with the ECDSA certificate, 2086
# with another CA added to TLS_CAFile, and 2087 with a Secret of its own.
clause() {   # clause PORT: the example's clause, on, at PORT
    sed -n '/^#<ServerRADSEC>/,/^#<\/ServerRADSEC>/p' /repo/radiator.example.conf \
        | sed "s/^#//; s/^\( *Port  *\)2083/\1$1/"
}
{
    clause 2084 | sed '/TLS_RequireClientCert/d; /TLS_CertificateVerifyFailedHook/d; s/^\( *\)#TLS_ExpectedPeerName/\1TLS_ExpectedPeerName/'
    clause 2085 | sed "s|$T/server.crt|$T/server-ec.crt|; s|$T/server.key|$T/server-ec.key|"
    clause 2086 | sed "s|$T/ca.crt|$T/ca-bundle.crt|"
    clause 2087 | sed 's/^\( *\)#Secret /\1Secret /'
} >>$CONF
check "radiusd -c accepts the configuration" ok \
    "$(su radiator -s /bin/sh -c "perl $RAD/radiusd -c -foreground -no_pid_file -config_file $CONF" >/dev/null 2>&1 && echo ok)"

# start_radiator [VAR=VALUE ...]: radiusd as user radiator, as the systemd
# unit runs it, with Trace 4 and the environment given (such as OPENSSL_CONF).
start_radiator() {
    pkill -f radiusd 2>/dev/null
    sleep 0.5
    rm -f "$LOG"
    su radiator -s /bin/sh -c "env $* perl $RAD/radiusd -foreground -no_pid_file -trace 4 -config_file $CONF" \
        >/tmp/radiusd.out 2>&1 &
    for _ in $(seq 50); do
        grep -qs 'Server started' "$LOG" && return
        sleep 0.2
    done
    echo "radiusd did not start:"; tail -20 "$LOG" /tmp/radiusd.out; exit 1
}

# hs PORT [s_client options]: the handshake openssl s_client makes with
# west.example.com, as "PROTOCOL CIPHER GROUP", or "refused: ALERT". The
# client sends no certificate unless the options give one. Its input stays
# open for 1.5 s, to read an alert that comes after the handshake (TLS 1.3).
hs() {
    local port=$1 out proto cipher group
    shift
    out=$( (sleep 1.5) | timeout 8 openssl s_client -brief -connect west.example.com:"$port" \
             -CAfile $T/ca.crt -verify_return_error "$@" 2>&1)
    proto=$(sed -n 's/^Protocol version: //p' <<<"$out" | head -1)
    cipher=$(sed -n 's/^Ciphersuite: //p' <<<"$out" | head -1)
    group=$(sed -n -e 's/^Negotiated TLS1.3 group: //p' -e 's/^\(Peer\|Server\) Temp Key: ECDH, \([^,]*\).*/\2/p' \
                   -e 's/^\(Peer\|Server\) Temp Key: \([^,]*\),.*/\2/p' <<<"$out" | head -1)
    if [[ -z $proto ]] || grep -q -i -E 'alert|error' <<<"$out"; then
        echo "refused: $(grep -o -m1 -E 'alert [a-z ]+' <<<"$out" | head -1)"
    else
        echo "$proto $cipher $group"
    fi
}
C=(-cert "$ADMIN"/nas1.crt -key "$ADMIN"/nas1.key)
SELF=(-cert "$ADMIN"/selfsigned.crt -key "$ADMIN"/selfsigned.key)
OTHER=(-cert "$ADMIN"/other.crt -key "$ADMIN"/other.key)
LAPTOP=(-cert "$ADMIN"/laptop.crt -key "$ADMIN"/laptop.key)
OK13="TLSv1.3 TLS_AES_256_GCM_SHA384 X25519MLKEM768"
OK12="TLSv1.2 ECDHE-RSA-AES256-GCM-SHA384 X25519"
NOCIPHER="refused: alert handshake failure"

start_radiator
echo
echo "== Step 4 of the guide: the handshake, from a test machine"
cp $T/ca.crt "$TESTER"/radsec-ca.crt
cd "$TESTER" || exit 1
field() { sed -n "s/^$1: //p" <<<"$out" | head -1; }   # field NAME: from s_client -brief
out=$(openssl s_client -brief -connect west.example.com:2083 -CAfile radsec-ca.crt </dev/null 2>&1)
check "TLS 1.3" "TLSv1.3 TLS_AES_256_GCM_SHA384 OK X25519MLKEM768" \
    "$(field 'Protocol version') $(field Ciphersuite) $(field Verification) $(field 'Negotiated TLS1.3 group')"
out=$(openssl s_client -brief -connect west.example.com:2083 -CAfile radsec-ca.crt -tls1_2 </dev/null 2>&1)
check "TLS 1.2" "TLSv1.2 ECDHE-RSA-AES256-GCM-SHA384 OK" \
    "$(field 'Protocol version') $(field Ciphersuite) $(field Verification)"
cd / || exit 1

echo
echo "== The default (port 2083): versions, ciphers and groups"
check "TLS 1.3" "$OK13" "$(hs 2083)"
check "TLS 1.2" "$OK12" "$(hs 2083 -tls1_2)"
check "TLS 1.3, client offers X25519 only" "TLSv1.3 TLS_AES_256_GCM_SHA384 X25519" "$(hs 2083 -groups X25519)"
check "TLS 1.3, client offers P-384 only" "TLSv1.3 TLS_AES_256_GCM_SHA384 secp384r1" "$(hs 2083 -groups secp384r1)"
check "TLS 1.3, client offers SecP384r1MLKEM1024 only (not in OpenSSL's defaults)" "$NOCIPHER" \
    "$(hs 2083 -groups SecP384r1MLKEM1024)"
check "TLS 1.3, AES-128-GCM only" "$NOCIPHER" "$(hs 2083 -ciphersuites TLS_AES_128_GCM_SHA256)"
check "TLS 1.3, ChaCha20 only" "$NOCIPHER" "$(hs 2083 -ciphersuites TLS_CHACHA20_POLY1305_SHA256)"
check "TLS 1.2, AES-128-GCM only" "$NOCIPHER" "$(hs 2083 -tls1_2 -cipher ECDHE-RSA-AES128-GCM-SHA256)"
check "TLS 1.2, AES-256-CBC only" "$NOCIPHER" "$(hs 2083 -tls1_2 -cipher ECDHE-RSA-AES256-SHA384)"
check "TLS 1.1" "refused: alert protocol version" "$(hs 2083 -tls1_1 -cipher 'DEFAULT@SECLEVEL=0')"

echo
echo "== The default (port 2083): client certificates"
check "TLS 1.3, our CA's certificate" "$OK13" "$(hs 2083 "${C[@]}")"
check "TLS 1.3, our CA's, any name" "$OK13" "$(hs 2083 "${LAPTOP[@]}")"
check "TLS 1.3, self-signed" "$OK13" "$(hs 2083 "${SELF[@]}")"
check "TLS 1.2, self-signed" "$OK12" "$(hs 2083 -tls1_2 "${SELF[@]}")"
check "TLS 1.3, another CA's" "$OK13" "$(hs 2083 "${OTHER[@]}")"
check "TLS 1.2, another CA's" "$OK12" "$(hs 2083 -tls1_2 "${OTHER[@]}")"
# The hook overrules only a problem with the client's own certificate, not
# with a chain it sends: those clients are refused.
check "TLS 1.3, another CA's, sent with that CA" "refused: alert unknown ca" \
    "$(hs 2083 "${OTHER[@]}" -cert_chain "$ADMIN"/other-ca.crt)"
check "TLS 1.2, another CA's, sent with that CA" "refused: alert unknown ca" \
    "$(hs 2083 -tls1_2 "${OTHER[@]}" -cert_chain "$ADMIN"/other-ca.crt)"
check "TLS 1.3, another CA's, sent with its intermediate" "refused: alert unknown ca" \
    "$(hs 2083 -cert "$ADMIN"/other2.crt -key "$ADMIN"/other2.key -cert_chain "$ADMIN"/other-int.crt)"

echo
echo "== Port 2086: the default, with that other CA added to TLS_CAFile"
check "TLS 1.3, sent with that CA" "$OK13" "$(hs 2086 "${OTHER[@]}" -cert_chain "$ADMIN"/other-ca.crt)"
check "TLS 1.3, sent with its intermediate" "$OK13" \
    "$(hs 2086 -cert "$ADMIN"/other2.crt -key "$ADMIN"/other2.key -cert_chain "$ADMIN"/other-int.crt)"
check "TLS 1.3, still no certificate needed" "$OK13" "$(hs 2086)"
check "TLS 1.3, still any self-signed" "$OK13" "$(hs 2086 "${SELF[@]}")"

echo
echo "== Port 2084: the option, mutual TLS with our CA"
check "TLS 1.3, our CA's certificate, a nasN name" "$OK13" "$(hs 2084 "${C[@]}")"
check "TLS 1.2, our CA's certificate, a nasN name" "$OK12" "$(hs 2084 -tls1_2 "${C[@]}")"
check "TLS 1.3, no certificate" "refused: alert certificate required" "$(hs 2084)"
check "TLS 1.2, no certificate" "$NOCIPHER" "$(hs 2084 -tls1_2)"
check "TLS 1.3, self-signed" "refused: alert unknown ca" "$(hs 2084 "${SELF[@]}")"
check "TLS 1.3, another CA's" "refused: alert unknown ca" "$(hs 2084 "${OTHER[@]}")"
check "TLS 1.3, our CA's, not a nasN name" "$NOCIPHER" "$(hs 2084 "${LAPTOP[@]}")"
check "TLS 1.2, our CA's, not a nasN name" "$NOCIPHER" "$(hs 2084 -tls1_2 "${LAPTOP[@]}")"
check "Radiator logged the refused name" yes \
    "$(grep -q 'Verification of certificate presented by 127.0.0.1' "$LOG" && echo yes)"

echo
echo "== Port 2085: the default, with an ECDSA P-384 certificate"
check "TLS 1.3" "$OK13" "$(hs 2085)"
check "TLS 1.2" "TLSv1.2 ECDHE-ECDSA-AES256-GCM-SHA384 X25519" "$(hs 2085 -tls1_2)"
check "radiusd still runs after the refusals" yes "$(pgrep -f radiusd >/dev/null && echo yes)"

# rsp NAME UDPPORT RADSECPORT CERT SECRET [TLSVERSION]: radsecproxy, with the
# guide's test configuration, taking RADIUS over UDP on UDPPORT (secret
# radsec-test) and sending it to Radiator's RADSECPORT over RadSec, with the
# client certificate CERT (in $ADMIN) and the shared secret SECRET.
rsp() {
    {
        printf 'ListenUDP 127.0.0.1:%s\ntls test {\n' "$2"
        printf '    CACertificateFile %s\n    CertificateFile %s\n    CertificateKeyFile %s\n' \
            $T/ca.crt "$ADMIN/$4.crt" "$ADMIN/$4.key"
        [[ -n ${6-} ]] && printf '    TlsVersion %s\n' "$6"
        printf '}\nclient localhost {\n    host 127.0.0.1\n    type udp\n    secret radsec-test\n}\n'
        printf 'server west {\n    host west.example.com\n    port %s\n    type tls\n    tls test\n    secret %s\n}\n' "$3" "$5"
        printf 'realm * {\n    server west\n}\n'
    } >/tmp/rsp-$1.conf
    radsecproxy -f -c /tmp/rsp-$1.conf >/tmp/rsp-$1.out 2>&1 &
    sleep 0.5
}
# says UDPPORT USER PASSWORD: Radiator's answer through a radsecproxy, from
# radpwtst: ACCEPT, "REJECT: <reason Radiator logged>", or NO-ANSWER.
says() {
    local out before
    before=$(wc -l <"$LOG")
    out=$(perl "$RAD/radpwtst" -s 127.0.0.1 -secret radsec-test -auth_port "$1" -noacct -timeout 5 \
            -user "$2" -password "$3" 2>&1)
    if grep -q '^OK' <<<"$out"; then
        echo ACCEPT
    elif grep -q -i 'reject' <<<"$out"; then
        sleep 0.1
        echo "REJECT: $(tail -n +$((before + 1)) "$LOG" | grep -o 'Access rejected for [^:]*: .*' | head -1 | sed 's/^[^:]*: //')"
    else
        echo NO-ANSWER
    fi
}
# until_accepted N: alice logs in through the TLS 1.3 radsecproxy with
# counters from N until one is accepted (for at most 60 s); prints the time
# it took, in seconds.
until_accepted() {
    local t0 n=$1
    t0=$(date +%s)
    while (( $(date +%s) - t0 < 60 )); do
        [[ $(says 11813 alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 $n 0)") == ACCEPT ]] && break
        n=$((n + 1))
    done
    echo $(( $(date +%s) - t0 ))
}

echo
echo "== Step 5 of the guide: a login with radclient through radsecproxy"
cd "$TESTER" || exit 1
openssl req -x509 -newkey rsa:3072 -nodes -days 30 -subj "/CN=radsec-test" -keyout test.key -out test.crt 2>/dev/null
cat >radsecproxy-test.conf <<EOF
ListenUDP 127.0.0.1:11812
tls test {
    CACertificateFile $PWD/radsec-ca.crt
    CertificateFile $PWD/test.crt
    CertificateKeyFile $PWD/test.key
}
client localhost {
    host 127.0.0.1
    type udp
    secret radsec-test
}
server west {
    host west.example.com
    port 2083
    type tls
    tls test
    secret radsec
}
realm * {
    server west
}
EOF
radsecproxy -f -c radsecproxy-test.conf >radsecproxy-test.log 2>&1 &
sleep 0.5
PIN=s3cr3t OTP=$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 1 0)
out=$(printf 'User-Name = "alice"\nUser-Password = "%s"\n' "$PIN:$OTP" | radclient -x 127.0.0.1:11812 auth radsec-test 2>&1)
check "radclient: the login" "Access-Accept" "$(grep -o -m1 'Received Access-[A-Za-z]*' <<<"$out" | cut -d' ' -f2)"
out=$(printf 'User-Name = "alice"\nUser-Password = "%s"\n' "$PIN:$OTP" | radclient -x 127.0.0.1:11812 auth radsec-test 2>&1)
check "radclient: the same OTP again" "Access-Reject" "$(grep -o -m1 'Received Access-[A-Za-z]*' <<<"$out" | cut -d' ' -f2)"
check "radsecproxy connected with TLS 1.3" "TLSv1.3 with cipher TLS_AES_256_GCM_SHA384" \
    "$(grep -o -m1 'TLSv1.3 with cipher [A-Z0-9_]*' radsecproxy-test.log)"
pkill -f radsecproxy-test.conf
cd / || exit 1

echo
echo "== Logins through radsecproxy with a self-signed certificate"
rsp tls13 11813 2083 selfsigned radsec TLS1_3
rsp tls12 11812 2083 selfsigned radsec TLS1_2
LOGIN_FROM=$(wc -l <"$LOG")
check "TLS 1.3: PIN and OTP" ACCEPT "$(says 11813 alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 2 0)")"
check "TLS 1.3: the same OTP again" "REJECT: Replay attack detected" "$(says 11813 alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 2 0)")"
check "TLS 1.3: wrong PIN" "REJECT: Bad static password" "$(says 11813 alice "wrong:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 3 0)")"
check "TLS 1.3: OTP made with another AES key" "REJECT: Bad Yubikey password" "$(says 11813 alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K2 4 0)")"
check "TLS 1.3: the next OTP" ACCEPT "$(says 11813 alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 5 0)")"
check "TLS 1.2: PIN and OTP" ACCEPT "$(says 11812 bob "b0bpin:$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1 0)")"
check "TLS 1.2: the same OTP again" "REJECT: Replay attack detected" "$(says 11812 bob "b0bpin:$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1 0)")"
check "TLS 1.2: an OTP already used over TLS 1.3" "REJECT: Replay attack detected" "$(says 11812 alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 5 0)")"
check "radsecproxy connected with TLS 1.2" "TLSv1.2 with cipher ECDHE-RSA-AES256-GCM-SHA384" \
    "$(grep -o -m1 'TLSv1.2 with cipher [A-Z0-9-]*' /tmp/rsp-tls12.out)"

echo
echo "== Many logins over one TLS 1.3 connection"
ok=0
for n in $(seq 101 200); do
    [[ $(says 11813 alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 "$n" 0)") == ACCEPT ]] && ok=$((ok + 1))
done
check "100 in a row: accepted" 100 "$ok"
# burst USER PUBLIC PRIVATE KEY PIN: 25 logins, with counters 1001 to 1025.
burst() {
    local ok=0 n
    for n in $(seq 1001 1025); do
        [[ $(says 11813 "$1" "$5:$(otp "$2" "$3" "$4" "$n" 0)") == ACCEPT ]] && ok=$((ok + 1))
    done
    echo "$ok" >"/tmp/burst-$1"
}
burst alice vvccccbbcdef 4a6f8e2d1c3b $K1 s3cr3t & b1=$!
burst bob   vvccccbbcdeg 4a6f8e2d1c3c $K2 b0bpin & b2=$!
burst carol vvccccbbcdbb 4a6f8e2d1c60 $K1 c4rol & b3=$!
burst dave  vvccccbbcdbc 4a6f8e2d1c61 $K2 d4ve & b4=$!
wait $b1 $b2 $b3 $b4
check "4 users at once, 25 each: accepted" 100 "$(cat /tmp/burst-{alice,bob,carol,dave} | awk '{ s += $1 } END { print s }')"
check "their counters saved" "1025 1025 1025 1025" \
    "$(sqlite3 /etc/radiator/db/yubicred.db "SELECT counter FROM yubikeys ORDER BY username" | paste -sd' ')"
check "no ERR lines in Radiator's log during the logins" 0 "$(tail -n +$((LOGIN_FROM + 1)) "$LOG" | grep -c ' ERR: ')"
tail -n +$((LOGIN_FROM + 1)) "$LOG" | grep ' ERR: ' | head -3

echo
echo "== Logins to the other listeners"
rsp mtls-ours 11814 2084 nas1 radsec
rsp mtls-self 11815 2084 selfsigned radsec
rsp secret-ok 11816 2087 selfsigned replace-with-a-long-random-secret
rsp secret-no 11817 2087 selfsigned radsec
check "mutual TLS, our CA's certificate, a nasN name" ACCEPT "$(says 11814 bob "b0bpin:$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1101 0)")"
check "mutual TLS, self-signed" NO-ANSWER "$(says 11815 bob "b0bpin:$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1102 0)")"
check "radsecproxy was refused with unknown ca" yes "$(grep -q 'alert unknown ca' /tmp/rsp-mtls-self.out && echo yes)"
check "a Secret of its own, the same on the client" ACCEPT "$(says 11816 bob "b0bpin:$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1103 0)")"
r=$(says 11817 bob "b0bpin:$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1104 0)")
check "a Secret of its own, radsec on the client" "not accepted" "$([[ $r == ACCEPT ]] && echo accepted || echo 'not accepted')"
# Stop the radsecproxy that keeps trying to connect, and is refused.
pkill -f rsp-mtls-self.conf

echo
echo "== Radiator restarts under radsecproxy"
# radsecproxy reconnects on its own timer: logins it gets before then are
# not sent, and get no answer.
start_radiator
between "a login gets through after a restart (s)" 0 60 "$(until_accepted 1100)"
pkill -f radiusd
sleep 1
check "a login while Radiator is down" NO-ANSWER "$(says 11813 alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 1199 0)")"
sleep 4
start_radiator
between "a login gets through after Radiator was down 10 s (s)" 0 60 "$(until_accepted 1200)"

echo
echo "== Key-exchange groups"
cat >$T/openssl.cnf <<'EOF'
openssl_conf = openssl_init
[openssl_init]
ssl_conf = ssl_sect
[ssl_sect]
system_default = system_default_sect
[system_default_sect]
Groups = X25519MLKEM768:SecP384r1MLKEM1024:X25519:secp384r1
EOF
start_radiator OPENSSL_CONF=$T/openssl.cnf
check "OPENSSL_CONF Groups: client defaults" "$OK13" "$(hs 2083)"
check "OPENSSL_CONF Groups: client offers SecP384r1MLKEM1024 only" "TLSv1.3 TLS_AES_256_GCM_SHA384 SecP384r1MLKEM1024" \
    "$(hs 2083 -groups SecP384r1MLKEM1024)"
check "OPENSSL_CONF Groups: client offers P-256 only" "$NOCIPHER" "$(hs 2083 -groups secp256r1)"
check "OPENSSL_CONF Groups: TLS 1.2" "$OK12" "$(hs 2083 -tls1_2)"
between "OPENSSL_CONF Groups: a login gets through (s)" 0 60 "$(until_accepted 1300)"
sed -i 's|^\( *\)TLS_CAFile\( *\)/etc/radiator/tls/ca.crt|\1TLS_ECDH_Curve        secp384r1\n&|' $CONF
start_radiator
check "TLS_ECDH_Curve secp384r1: client defaults" "TLSv1.3 TLS_AES_256_GCM_SHA384 secp384r1" "$(hs 2083)"
check "TLS_ECDH_Curve secp384r1: client offers X25519MLKEM768 only" "$NOCIPHER" "$(hs 2083 -groups X25519MLKEM768)"
sed -i '/TLS_ECDH_Curve/d' $CONF

echo
echo "== A slow login holds up the others on its RadSec connection (PostgreSQL)"
# One Radiator process serves each RadSec connection; FarmSize spreads
# connections over processes, not requests. alice's row is locked for 1.5 s
# (less than the SQL Timeout of 2 s), so her login waits; bob logs in 0.3 s
# after her.
pg_ctlcluster 18 main start
su postgres -c "$Y -b pg init-pg --admin root" >/dev/null
"$Y" -b pg add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $K1 -w s3cr3t >/dev/null
"$Y" -b pg add -u bob   -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $K2 -w b0bpin >/dev/null
"$Y" -b pg config >/etc/radiator/conf.d/yubikey.conf
start_radiator
sleep 11   # past the first 10 s after connecting, when the SQL Timeout is 6 s
# timed PORT SECRET USER PASSWORD: "ANSWER MILLISECONDS".
timed() {
    local t0 out
    t0=$(now_ms)
    out=$(perl "$RAD/radpwtst" -s 127.0.0.1 -secret "$2" -auth_port "$1" -noacct -timeout 8 \
            -user "$3" -password "$4" 2>&1)
    if grep -q '^OK' <<<"$out"; then echo "ACCEPT $(( $(now_ms) - t0 ))"; else echo "NO $(( $(now_ms) - t0 ))"; fi
}
LOCK="su postgres -c \"psql -X -q -d yubikey -c \\\"BEGIN; UPDATE yubikeys SET accessed = accessed WHERE username = 'alice'; SELECT pg_sleep(1.5); COMMIT;\\\"\" >/dev/null"
# held PORT SECRET N: alice logs in while her row is locked, and bob 0.3 s
# later; prints bob's answer and time, then alice's.
held() {
    local l a
    eval "$LOCK" & l=$!
    sleep 0.2
    timed "$1" "$2" alice "s3cr3t:$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 "$3" 0)" >/tmp/alice & a=$!
    sleep 0.3
    timed "$1" "$2" bob "b0bpin:$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 "$3" 0)"
    wait "$l" "$a"
    cat /tmp/alice
}
between "RadSec works again after the restart (s)" 0 60 "$(until_accepted 1)"
check "UDP works" ACCEPT "$(timed 1812 local-test-secret bob "b0bpin:$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1 0)" | cut -d' ' -f1)"
mapfile -t r < <(held 1812 local-test-secret 100)
check "UDP: both accepted" "ACCEPT ACCEPT" "${r[0]%% *} ${r[1]%% *}"
between "UDP: bob's login, while alice's waits (ms)" 0 600 "${r[0]#* }"
mapfile -t r < <(held 11813 radsec-test 200)
check "RadSec: both accepted" "ACCEPT ACCEPT" "${r[0]%% *} ${r[1]%% *}"
between "RadSec: bob's login, while alice's waits (ms)" 800 2000 "${r[0]#* }"

echo
echo "== Configuration mistakes"
pkill radsecproxy
sed -i '/^<ServerRADSEC>/,/^<\/ServerRADSEC>/d' $CONF
clause 2083 | sed '/TLS_CertificateType/d' >>$CONF
clause 2084 | sed '/TLS_CAFile/d' >>$CONF
start_radiator
check "without TLS_CertificateType PEM" refused "$(hs 2083 | cut -d: -f1)"
check "Radiator logged why" yes "$(grep -q 'could not use TLS_CertificateFile' "$LOG" && echo yes)"
check "without TLS_CAFile" refused "$(hs 2084 | cut -d: -f1)"
check "Radiator logged why" yes "$(grep -q 'could not load TLS_CAFile' "$LOG" && echo yes)"

echo
printf 'RadSec: %d passed, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
