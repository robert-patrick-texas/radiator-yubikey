#!/usr/bin/env bash
#
# make-otp.sh - Print the OTP that a YubiKey programmed with these values would
# type, so logins can be tested without a YubiKey. The tests use it, and so
# can you, with test keys.
#
# Usage: tests/make-otp.sh PUBLIC_ID PRIVATE_ID AES_KEY COUNTER [SESSION]
#   PUBLIC_ID   the YubiKey's public ID (12 modhex characters)
#   PRIVATE_ID  its private ID (12 hex characters)
#   AES_KEY     its AES key (32 hex characters)
#   COUNTER     usage counter, 0-65535 (Radiator ignores the top bit, 32768)
#   SESSION     session counter, 0-255 (default 0)
#
# Radiator accepts an OTP only if its COUNTER is higher than the last one used,
# or the same with a higher SESSION. The AES key is passed to openssl on its
# command line, where other users can see it: use this with test keys only.
#
# Needs perl and openssl.

set -euo pipefail

die() { printf 'make-otp.sh: error: %s\n' "$*" >&2; exit 1; }

[[ $# -eq 4 || $# -eq 5 ]] || die "usage: make-otp.sh PUBLIC_ID PRIVATE_ID AES_KEY COUNTER [SESSION]"
pub=${1,,} priv=${2,,} key=${3,,} counter=$4 session=${5:-0}
[[ $pub =~ ^[cbdefghijklnrtuv]*$ ]] || die "PUBLIC_ID must be modhex (cbdefghijklnrtuv)"
[[ $priv =~ ^[0-9a-f]{12}$ ]] || die "PRIVATE_ID must be 12 hex characters"
[[ $key =~ ^[0-9a-f]{32}$ ]] || die "AES_KEY must be 32 hex characters"
if ! [[ $counter =~ ^[0-9]{1,5}$ ]] || (( counter > 65535 )); then die "COUNTER must be 0-65535"; fi
if ! [[ $session =~ ^[0-9]{1,3}$ ]] || (( session > 255 )); then die "SESSION must be 0-255"; fi

# The 16-byte token: private ID, usage counter, timestamp (3 bytes), session
# counter, random (2 bytes), then a CRC-16 that makes the whole token check out.
printf '%s' "$pub"
perl -e '
    my ($priv, $counter, $session) = @ARGV;
    my $token = pack("H12 v C3 C v", $priv, $counter, 0x12, 0x34, 0x00, $session, 0xbeef);
    my $crc = 0xffff;
    for my $b (unpack "C*", $token) {
        $crc ^= $b;
        for (1 .. 8) { my $lsb = $crc & 1; $crc >>= 1; $crc ^= 0x8408 if $lsb }
    }
    print $token, pack("v", ~$crc & 0xffff);' "$priv" "$counter" "$session" \
    | openssl enc -aes-128-ecb -nopad -K "$key" \
    | perl -e 'local $/; (my $h = unpack "H*", <STDIN>) =~ tr/0-9a-f/cbdefghijklnrtuv/; print $h, "\n"'
