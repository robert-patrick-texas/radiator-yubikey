#!/bin/bash
#
# e2e.sh - Runs inside the container that tests/radiator/run.sh builds, with
# the repository at /repo (read-only). Sets up databases with yubikey-db.sh,
# runs Radiator (radiusd) with the clause from 'yubikey-db.sh config', logs in
# with radpwtst, and checks each answer and Radiator's logged reason against
# the expected one. It also checks that 'yubikey-db.sh verify' reaches the
# same verdict as Radiator, and that the example wrapper's records work.
# Covers SQLite (with and without Require2Factor) and PostgreSQL.
#
# OTPs are made the same way as in tests/run-tests.sh: encrypted with openssl,
# independently of both Radiator and verify.

set -uo pipefail

Y=/repo/yubikey-db.sh
RAD=/opt/radiator/radiator
DB=/etc/radiator/db/yubicred.db
K1=6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d
K2=0f1e2d3c4b5a69788796a5b4c3d2e1f0
B=()          # backend options for yubikey-db.sh
VOPTS=()      # verify options that match Radiator's configuration
pass=0 fail=0

# otp PUBLIC_ID PRIVATE_ID AES_KEY COUNTER SESSION: the OTP such a YubiKey types.
otp() {
    printf '%s' "$1"
    perl -e '
        my ($priv, $counter, $session) = @ARGV;
        my $token = pack("H12 v C3 C v", $priv, $counter, 0x12, 0x34, 0x00, $session, 0xbeef);
        my $crc = 0xffff;
        for my $b (unpack "C*", $token) {
            $crc ^= $b;
            for (1 .. 8) { my $lsb = $crc & 1; $crc >>= 1; $crc ^= 0x8408 if $lsb }
        }
        print $token, pack("v", ~$crc & 0xffff);' "$2" "$4" "$5" \
        | openssl enc -aes-128-ecb -nopad -K "$3" \
        | perl -e 'local $/; (my $h = unpack "H*", <STDIN>) =~ tr/0-9a-f/cbdefghijklnrtuv/; print $h'
}

# Write Radiator's configuration around the clause from 'yubikey-db.sh config';
# "no2fa" removes Require2Factor.
make_conf() {
    {
        printf 'DictionaryFile %s/dictionary\nLogDir /tmp/rad\nLogFile %%L/radiusd.log\n' "$RAD"
        printf 'BindAddress 127.0.0.1\nAuthPort 1812\nAcctPort 1813\n'
        printf '<Client 127.0.0.1>\n    Secret testing123\n</Client>\n<Handler>\n'
        "$Y" "${B[@]}" config | grep -v '^#' | sed 's/^/    /'
        printf '</Handler>\n'
    } >/tmp/rad/test.conf
    if [[ ${1-} == no2fa ]]; then sed -i '/^ *Require2Factor/d' /tmp/rad/test.conf; fi
}

# Start radiusd as the radiator user, as the packaged systemd unit does.
start_radiator() {
    pkill -f radiusd 2>/dev/null
    sleep 0.5
    rm -f /tmp/rad/radiusd.log
    su radiator -s /bin/sh -c "perl $RAD/radiusd -foreground -trace 4 -config_file /tmp/rad/test.conf" \
        >/tmp/rad/stdout.log 2>&1 &
    for _ in $(seq 50); do
        grep -qs 'Server started' /tmp/rad/radiusd.log && return
        sleep 0.2
    done
    echo "radiusd did not start:"; tail -20 /tmp/rad/radiusd.log /tmp/rad/stdout.log; exit 1
}

# Radiator's answer to one login: "ACCEPT", or "REJECT: <reason it logged>".
radiator_says() {
    local out before
    before=$(wc -l </tmp/rad/radiusd.log)
    out=$(perl "$RAD/radpwtst" -s 127.0.0.1 -secret testing123 -auth_port 1812 -noacct \
            -user "$1" -password "$2" 2>&1)
    if grep -q '^OK' <<<"$out"; then
        echo ACCEPT
    else
        sleep 0.1
        echo "REJECT: $(tail -n +$((before + 1)) /tmp/rad/radiusd.log \
                        | grep -o 'Access rejected for [^:]*: .*' | head -1 | sed 's/^[^:]*: //')"
    fi
}

# verify's answer, ACCEPT or REJECT: verify_says USER PASSWORD OTP [live]. It
# runs on a copy of the SQLite database, so it does not use up the OTP,
# unless "live" is given (always for PostgreSQL).
verify_says() {
    local -a db=()
    if [[ ${#B[@]} -eq 0 && ${4-} != live ]]; then
        cp "$DB" /tmp/verify-copy.db
        db=(-d /tmp/verify-copy.db)
    fi
    if printf '%s\n%s\n' "$2" "$3" | "$Y" "${B[@]}" "${db[@]}" verify -u "$1" "${VOPTS[@]}" >/dev/null 2>&1; then
        echo ACCEPT
    else
        echo REJECT
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

# login LABEL EXPECTED USER PASSWORD OTP [nocolon]: ask verify (unless the
# database is PostgreSQL), then Radiator, and check both answers.
login() {
    local label=$1 expected=$2 user=$3 pw=$4 otp=$5 submitted r
    submitted=$otp
    if [[ -n $pw ]]; then submitted="$pw:$otp"; fi
    if [[ ${6-} == nocolon ]]; then submitted="$pw$otp"; fi
    if [[ ${#B[@]} -eq 0 ]]; then
        check "$label (verify)" "${expected%%:*}" "$(verify_says "$user" "$pw" "$otp")"
    fi
    r=$(radiator_says "$user" "$submitted")
    check "$label (Radiator)" "$expected" "$r"
}

mkdir -p /tmp/rad && chmod 777 /tmp/rad

echo "== SQLite, with the clause from 'yubikey-db.sh config' (Require2Factor, CheckSecretId)"
"$Y" init --owner radiator:radiator >/dev/null 2>&1
"$Y" add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $K1 -w s3cr3t >/dev/null
"$Y" -e hex add -u hexie -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $K2 -w s3cr3t >/dev/null
"$Y" add -u otponly -P vvccccbbcdeh -p 4a6f8e2d1c3d -k $K1 --no-password >/dev/null
"$Y" add -u inactive -P vvccccbbcdei -p 4a6f8e2d1c3e -k $K1 -w s3cr3t --inactive >/dev/null
"$Y" add -u truey -P vvccccbbcdej -p 4a6f8e2d1c3f -k $K1 -w s3cr3t >/dev/null
"$Y" add -u falsey -P vvccccbbcdek -p 4a6f8e2d1c40 -k $K1 -w s3cr3t >/dev/null
"$Y" -H clear add -u clearpw -P vvccccbbcdel -p 4a6f8e2d1c41 -k $K1 -w 'plain pw' >/dev/null
# Rows the script would not create: text active values, a 16-character public ID.
sqlite3 "$DB" "UPDATE yubikeys SET active = 'true' WHERE username = 'truey';
    UPDATE yubikeys SET active = 'false' WHERE username = 'falsey';
    INSERT INTO yubikeys SELECT 'longpub', password, 1, created, '', 'vvccccbbcdefghij', '4a6f8e2d1c42', secret, 0, 0, 0
      FROM yubikeys WHERE username = 'alice';"
make_conf
start_radiator

login "password:OTP"                    ACCEPT alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 1 0)"
login "the same OTP again"              "REJECT: Replay attack detected" alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 1 0)"
login "passwordOTP, no colon"           ACCEPT alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 1 1)" nocolon
login "wrong password"                  "REJECT: Bad static password" alice wrong "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 2 0)"
login "OTP without the password"        "REJECT: Bad static password" alice '' "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 2 1)"
login "OTP made with another AES key"   "REJECT: Bad Yubikey password" alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K2 3 0)"
login "OTP with another private ID"     "REJECT: Bad Yubikey Secret-Id" alice s3cr3t "$(otp vvccccbbcdef 111111111111 $K1 3 0)"
login "trigger bit set (counter 0x8004)" ACCEPT alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 $((0x8004)) 0)"
login "next OTP (counter 5)"            ACCEPT alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 5 0)"
login "AES key stored as hex"           ACCEPT hexie s3cr3t "$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1 0)"
login "no stored password"              "REJECT: Bad static password" otponly '' "$(otp vvccccbbcdeh 4a6f8e2d1c3d $K1 1 0)"
login "active=0"                        "REJECT: Yubikey is not active" inactive s3cr3t "$(otp vvccccbbcdei 4a6f8e2d1c3e $K1 1 0)"
login "active='true'"                   ACCEPT truey s3cr3t "$(otp vvccccbbcdej 4a6f8e2d1c3f $K1 1 0)"
login "active='false'"                  ACCEPT falsey s3cr3t "$(otp vvccccbbcdek 4a6f8e2d1c40 $K1 1 0)"
login "password stored in clear text"   ACCEPT clearpw 'plain pw' "$(otp vvccccbbcdel 4a6f8e2d1c41 $K1 1 0)"
login "16-character public ID"          "REJECT: Yubikey secret not found in database" longpub s3cr3t "$(otp vvccccbbcdefghij 4a6f8e2d1c42 $K1 1 0)"
check "UpdateQuery saved counter/low/high" "5|0|0" \
    "$(sqlite3 "$DB" "SELECT counter || '|' || low || '|' || high FROM yubikeys WHERE username = 'alice';")"

# verify saves counters on the live database, and Radiator must accept the next
# OTP: the trigger bit must not be saved as part of the counter.
r=$(printf '%s\n%s\n' s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 $((0x8010)) 0)" | "$Y" verify -u alice 2>&1 | tail -1)
check "verify, trigger bit set (counter 0x8010)" "Accepted. The OTP's counters were saved, so it cannot be used again." "$r"
check "verify saved the counter without the trigger bit" "16" "$(sqlite3 "$DB" "SELECT counter FROM yubikeys WHERE username = 'alice';")"
login "next OTP after verify (counter 17)" ACCEPT alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 17 0)"

echo
echo "== SQLite, without Require2Factor"
make_conf no2fa
start_radiator
VOPTS=(--no-require2factor)
login "no stored password, OTP only"    ACCEPT otponly '' "$(otp vvccccbbcdeh 4a6f8e2d1c3d $K1 2 0)"
login "password not entered"            ACCEPT alice '' "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 18 0)"
login "wrong password entered"          "REJECT: Bad static password" alice wrong "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 19 0)"
login "password entered, none stored"   "REJECT: Bad static password" otponly x "$(otp vvccccbbcdeh 4a6f8e2d1c3d $K1 3 0)"
VOPTS=()

echo
echo "== The example wrapper (SQLite, Require2Factor)"
make_conf
start_radiator
wrapper() {    # wrapper NAME=VALUE...: run a copy of the wrapper with these settings
    local -a edits=(-e "s|^yubikey_db=''|yubikey_db='$Y'|")
    local kv
    for kv in "$@"; do edits+=(-e "s|^${kv%%=*}=[^ ]*|${kv%%=*}='${kv#*=}'|"); done
    sed "${edits[@]}" /repo/yubikey-db-user.example.sh >/tmp/user.sh
    chmod 700 /tmp/user.sh
    /tmp/user.sh </dev/null >/dev/null 2>&1
}
rec=(cred_username=wrapped cred_publicid=vvccccbbcder cred_privateid=4a6f8e2d1c50)
wrapper "${rec[@]}" cred_secret=$K1 cred_password=first
login "record added by the wrapper"     ACCEPT wrapped first "$(otp vvccccbbcder 4a6f8e2d1c50 $K1 4 0)"
wrapper "${rec[@]}" cred_secret=$K1 cred_password=second
login "old OTP after a password change" "REJECT: Replay attack detected" wrapped second "$(otp vvccccbbcder 4a6f8e2d1c50 $K1 3 0)"
login "new password, next OTP"          ACCEPT wrapped second "$(otp vvccccbbcder 4a6f8e2d1c50 $K1 5 0)"
wrapper "${rec[@]}" cred_secret=$K2 cred_password=second
login "reprogrammed key, counter 1"     ACCEPT wrapped second "$(otp vvccccbbcder 4a6f8e2d1c50 $K2 1 0)"

echo
echo "== PostgreSQL, Radiator logging in as role radiator over the local socket"
pkill -f radiusd
pg_ctlcluster 18 main start
su postgres -c "$Y -b pg init-pg --admin root" >/dev/null
B=(-b pg)
"$Y" -b pg add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k $K1 -w s3cr3t >/dev/null
"$Y" -b pg -e hex add -u hexie -P vvccccbbcdeg -p 4a6f8e2d1c3c -k $K2 -w s3cr3t >/dev/null
"$Y" -b pg add -u inactive -P vvccccbbcdei -p 4a6f8e2d1c3e -k $K1 -w s3cr3t --inactive >/dev/null
make_conf
start_radiator
login "password:OTP"                    ACCEPT alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 1 0)"
login "the same OTP again"              "REJECT: Replay attack detected" alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 1 0)"
login "wrong password"                  "REJECT: Bad static password" alice wrong "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 2 0)"
login "AES key stored as hex"           ACCEPT hexie s3cr3t "$(otp vvccccbbcdeg 4a6f8e2d1c3c $K2 1 0)"
login "active=0"                        "REJECT: Yubikey is not active" inactive s3cr3t "$(otp vvccccbbcdei 4a6f8e2d1c3e $K1 1 0)"
check "to_timestamp(%5) set accessed" "t" \
    "$(psql -X -At -d yubikey -c "SELECT accessed > now() - interval '1 minute' FROM yubikeys WHERE username = 'alice';")"
# verify and Radiator share the counters.
check "verify, counter 3" ACCEPT "$(verify_says alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 3 0)" live)"
login "older OTP after verify (counter 2)" "REJECT: Replay attack detected" alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 2 1)"
login "newer OTP after verify (counter 4)" ACCEPT alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 4 0)"
check "verify, an OTP Radiator accepted" REJECT "$(verify_says alice s3cr3t "$(otp vvccccbbcdef 4a6f8e2d1c3b $K1 4 0)" live)"

echo
printf 'Radiator %s: %d passed, %d failed\n' \
    "$(dpkg-query -W -f '${Version}' radiator)" "$pass" "$fail"
[[ $fail -eq 0 ]]
