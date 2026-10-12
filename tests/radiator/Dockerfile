# Ubuntu 26.04 with Radiator, the Perl modules its YubiKey support needs, SQLite
# and PostgreSQL 18. Built by tests/radiator/run.sh, which copies the Radiator
# packages next to this file.
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
COPY *.deb /tmp/radiator/
RUN apt-get update \
 && apt-get install -y --no-install-recommends /tmp/radiator/*.deb \
      libauth-yubikey-decrypter-perl libcrypt-rijndael-perl libdbd-sqlite3-perl libdbd-pg-perl \
      sqlite3 postgresql postgresql-client openssl procps \
 && rm -rf /var/lib/apt/lists/* /tmp/radiator
