# Ubuntu 26.04 with Radiator, the Perl modules its YubiKey support needs, SQLite,
# PostgreSQL 18, and Patroni and etcd for the three-site test. Built by
# tests/radiator/run.sh, which copies the Radiator packages next to this file.
FROM ubuntu:26.04
ENV DEBIAN_FRONTEND=noninteractive
COPY *.deb /tmp/radiator/
RUN apt-get update \
 && apt-get install -y --no-install-recommends /tmp/radiator/*.deb \
      libauth-yubikey-decrypter-perl libcrypt-rijndael-perl libcache-fastmmap-perl \
      libdbd-sqlite3-perl libdbd-pg-perl \
      sqlite3 postgresql postgresql-client openssl procps sudo \
      patroni python3-etcd etcd-server etcd-client iproute2 curl \
 && rm -rf /var/lib/apt/lists/* /tmp/radiator
