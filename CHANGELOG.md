# Changelog

## 1.6.0 - 2026-10-13

The scripts as a Debian package, `radiator-yubikey`, in
`/opt/radiator-yubikey`, and `install.sh`, which installs it with the
packages that it and Radiator need, after checking that Radiator is
installed, from Radiator Software's packages or from their source.

### Added

- The MIT license (`LICENSE`).
- The `radiator-yubikey` package, built by `packaging/build-deb.sh` from
  `packaging/debian/` (the same files always build the same package): the
  scripts, their examples, `tests/make-otp.sh`, the HTML guide, README and
  changelog in `/opt/radiator-yubikey`, and `yubikey-partition.service` and
  `yubikey-anycast.service`, neither enabled nor started. An upgrade
  restarts the services that run and leaves stopped ones stopped; a removal
  stops them. It depends on `perl` and `sqlite3` or `postgresql-client`, not
  on Radiator, so that either kind of Radiator works.
- `install.sh`: looks for Radiator (Radiator Software's `radiator` or
  `radiator-locked` package, or a `radiusd` from their source, in
  `/opt/radiator/radiator`, on the `PATH`, or given with `--radiusd`).
  Without it, says how to install it and asks whether to go on; with no
  terminal, stops (exit status 3) unless `--yes`. Then installs with
  `apt-get` the Perl modules that Radiator's YubiKey support and
  `DupCache shared` need, the SQLite and PostgreSQL drivers and tools, and
  the package; checks that Radiator's Perl loads Radiator's SQLYUBIKEY
  module and those modules; and lists what is left to do (for Radiator from
  source, a missing `radiator` user or `radiator.service`; units installed
  by hand that hide the package's, with the commands that replace them).
  `--check` changes nothing.
- `tests/radiator/package.sh` (in `run.sh`), 48 checks: the package builds
  the same twice, lintian finds nothing, and nothing is outside
  `/opt/radiator-yubikey` but its units; `install.sh` on fresh Ubuntu 26.04
  containers without Radiator, with Radiator Software's packages, and with
  Radiator's source unpacked in `/opt/radiator/radiator` or installed with
  `make install`, each with a login through Radiator; the units under
  systemd through an install, an upgrade, a removal and a purge.
- `tests/run-tests.sh`: the `install` scenario, `install.sh` with stand-ins
  for `apt-get`, `dpkg-query` and Radiator.

### Changed

- `yubikey-partition.service` and `yubikey-anycast.service` run the scripts
  in `/opt/radiator-yubikey`, not `/usr/local/sbin`.
- Guide: installs the scripts with the package (or a clone in
  `/opt/radiator-yubikey`, not `/opt/yubikey-db`), covers Radiator from its
  source, and says how to move from scripts and units installed by hand.
  Partition mode and anycast no longer copy scripts and units.
- `tests/radiator/geo.sh` installs the package on the three sites; the test
  image has debhelper and lintian.

### Fixed

- `yubikey-partition.sh` read its copy of the keys without waiting for a
  writer to finish. While Radiator was saving a counter in the copy, or the
  copy was being updated, leaving partition mode failed with "database is
  locked" and waited for a later check, and the copy's size in `setup`,
  `sync`, `status` and the service's log could be blank. Its reads now wait
  up to 10 s, as its writes already did (and the size shows `?` if the copy
  still can't be read). `tests/run-tests.sh`: `pg_partition` leaves
  partition mode while the copy is locked.
- `tests/radiator/geo.sh` could fail now and then: reading a site's copy of
  the keys while partition mode's service was updating it ("database is
  locked"; it now waits for the lock), and the replayed OTP at West right
  after its cut was healed, before every Radiator process had reconnected
  (it now retries while the answer is "secret not found", as other checks
  after a cut do).

## 1.5.0 - 2026-10-13

Partition mode: a site that can reach no other site logs users in from a
copy of the keys on its own server, and copies the counters back to the
primary when the network returns.

### Added

- `yubikey-partition.sh`, with `yubikey-partition.service` and
  `yubikey-partition.example.conf`: every 5 minutes it updates a SQLite
  copy of the keys from the server's own PostgreSQL (counters only move
  forward). When neither of the other servers has answered for 3 checks (5 s
  apart), it updates the copy once more (a standby that is cut off still
  answers reads), points Radiator's `yubikey.conf` (now a link) at the
  copy's clause and restarts Radiator. A former primary, whose PostgreSQL
  Patroni is stopping, uses the last copy until PostgreSQL answers again. When another server answers and the primary can be reached, it
  copies the counters that moved forward in the copy to the primary (only
  forward, with Radiator's own login), points the link back at the cluster,
  restarts Radiator, and copies once more.
- Guide: "Partition mode": how it works, the risks it accepts (an OTP used
  at another site works once more at the cut-off site; changes reach it
  only when the network is back), what users see, as measured, the setup,
  running it, security notes and troubleshooting rows.
- `tests/radiator/geo.sh`: partition mode with West cut off, the primary's
  site cut off, two servers down at once, and the link between the East
  sites broken (no partition mode: East2 still reaches West).
- `tests/run-tests.sh`: the `pg_partition` scenario: the copy follows the
  database, the counters go back only forward, and the service switches
  Radiator's clause both ways.

### Fixed

- `tests/radiator/ha.sh` could fail now and then on a replayed OTP right
  after a failover: one of Radiator's four processes had not reconnected yet
  and answered `Yubikey secret not found in database`. Those checks now
  wait for an answer from the database.

## 1.4.0 - 2026-10-13

One anycast address for all sites: each server advertises it with BGP only
while its Radiator accepts logins.

### Added

- `yubikey-anycast.sh`, with `yubikey-anycast.service` and
  `yubikey-anycast.example.conf`: every 5 s it logs in to the local Radiator
  with a YubiKey key of its own (made by `enroll`, loaded with
  `yubikey-db.sh import --replace -`) and checks that Radiator listens on the
  anycast addresses. After 2 good checks it puts the addresses (IPv4 and
  IPv6) on `lo`, where FRR advertises them; after 3 failed checks, or when it
  stops, it takes them off, and FRR withdraws them. `status` shows the state
  and how many OTPs the key has left (485 days at one check every 5 s).
- `radiator.example.conf`: the check's users (`anycast-*`) can log in only
  from 127.0.0.1, without entries in the authentication log; and a
  commented-out `BindAddress` for anycast.
- Guide: "Anycast": how it works, what devices see in each failure, as
  measured, the setup on each server (FRR with BGP and BFD, Radiator's
  `BindAddress`, `ip_nonlocal_bind`, the check), what the routers need,
  maintenance, security notes and troubleshooting rows.
- `tests/radiator/geo.sh`: an FRR router for West and a RADIUS client behind
  it, on IPv4 and IPv6; the anycast checks run through every failure of the
  three-site test, plus West's Radiator stopping, its check stopping, and
  West losing power (BFD).
- `tests/run-tests.sh`: the `anycast` and `anycast_run` scenarios, against a
  stand-in RADIUS server that checks requests as Radiator does.

### Changed

- The HTML guide links to the GitHub repository (header and footer), and
  the guide names it in its introduction.
- The guide and the three-site test call the sites only West, East1 and
  East2, without their locations.

### Found while testing

- Radiator 4.30 starts even when it can't listen on an address in
  `BindAddress` (it logs `Could not bind authentication socket: Cannot
  assign requested address`), and then never answers there. The guide sets
  `ip_nonlocal_bind`, and the check also makes sure Radiator listens on the
  anycast addresses.

## 1.3.0 - 2026-10-13

Three sites with automatic failover: a tested setup with etcd, PostgreSQL
under Patroni, and Radiator on each of three sites.

### Added

- Guide: "Three sites": how etcd, Patroni and quorum commit keep one primary
  and lose no OTP in a failover; what users see in each failure, as
  measured; the setup (packages, certificates, etcd, Patroni, the database,
  Radiator); switchovers, reboots, copying a standby again; what happens
  when a site is cut off. West, 55 ms from the East sites, becomes the
  primary only as a last resort (`failover_priority`). Troubleshooting rows
  for four Patroni problems found while building it, and security notes.
- `tests/radiator/geo.sh` (with `geo-node.sh`): 90 checks with three
  systemd containers, one per site, and traffic control adding the WAN
  delays. It measures login times per site, and goes through a reboot of
  each server, a power loss and a Patroni crash on the primary, West cut
  off, the primary's site cut off, the link between the East sites broken,
  a standby copied again, and two servers down at once. `run.sh DIR geo`
  runs it alone; the test image also has Patroni, etcd, iproute2 and curl.

### Found while testing

- Patroni's check of whether a former primary must be rewound connects to
  `localhost` with the replication settings; with `sslmode=verify-full`
  that fails, and a former primary with a commit no standby confirmed never
  rejoins. The guide's configuration uses the local socket for it
  (`use_unix_socket_repl`).
- Debian's `patroni@` unit doesn't restart Patroni after a crash, leaving
  PostgreSQL running unattended; the guide adds `Restart=on-failure`.
- The `patroni` package doesn't install `python3-etcd`, which it needs for
  etcd, and Patroni (Python 3.14) refuses a CA certificate without
  `keyUsage`.

## 1.2.1 - 2026-10-13

The same OTP is now accepted only once even when it reaches two Radiator
servers, or two Radiator processes, at the same moment; and
`radiator.example.conf` runs a Radiator farm.

### Fixed

- **The same OTP could be accepted twice at the same moment.** Radiator reads
  the counters, checks the OTP, then saves the counters with an `UPDATE` that
  succeeds even when another login has just saved the same values. Two
  requests with the same OTP that both read the counters before either
  saved them were both accepted: on two Radiator servers sharing a
  PostgreSQL database, or on two processes of one Radiator farm. A new
  trigger, `yubikeys_counters_forward` (SQLite and PostgreSQL), refuses a
  save that doesn't move the counters forward; Radiator then gives the
  second request no answer (`Database update failed`). The tests reproduce
  the race with a lock that holds both saves: before the trigger both
  logins were accepted, with it exactly one.
  **Existing databases: run `init` again** (`sudo ./yubikey-db.sh init
  --owner radiator:radiator`, or `./yubikey-db.sh -b pg init` as an admin,
  once against the primary) to add the trigger.

### Changed

- `radiator.example.conf` runs four Radiator processes (`FarmSize 4`), so
  one slow database query no longer holds up every other login, with
  `DupCache shared` so a retransmitted request is recognized by every
  process. This needs `libcache-fastmmap-perl` (the Radiator package only
  suggests it), and the cache file, about 290 MB, is kept at
  `/var/lib/radiator/dupcache` rather than in `/tmp`, which may be held in
  memory.
- Each farm process has its own database connection and
  `FailureBackoffTime`, so after a database failure the first login in each
  process may take 2 to 5 s; logins work again sooner after a promotion
  (3 to 5 s in the test).
- `init` help and docs say that it also brings a database made by an older
  version up to date.

### Tests

- `tests/run-tests.sh`: new `counters` scenario (SQLite), trigger checks in
  `pg_radiator`, the trigger in the `pg_init` schema listing; 34 scenarios.
- `tests/radiator/e2e.sh`: the race in two farm processes, SQLite and
  PostgreSQL, with and without the trigger; 92 checks.
- `tests/radiator/ha.sh`: the race across two Radiator servers, and `init`
  from the admin's host adding the trigger on the primary (and, by
  replication, the standby); 56 checks.

## 1.2.0 - 2026-10-12

Two PostgreSQL servers: a primary and a streaming standby that Radiator
follows when it is promoted, tested through failures with two Radiator
servers.

### Added

- `config`, with several hosts in `PGHOST` (`PGHOST=db1,db2`), writes one
  `DBSource` with both hosts and `target_session_attrs=read-write`: libpq
  connects only to the server that accepts writes, so every Radiator server
  uses the primary, and follows the standby once it is promoted.
- `yubikey-db.sh` and `yubikey-db-migrate.sh` send their changes to the
  writable server too: with several hosts in `PGHOST`,
  `PGTARGETSESSIONATTRS` defaults to `read-write`.
- `tests/radiator/ha.sh` (run by `tests/radiator/run.sh`, or alone with
  `run.sh DIR ha`): two PostgreSQL servers with asynchronous replication over
  TLS and two Radiator servers, in four containers, through a dead primary, a
  hung primary, failovers, a planned switchover, and an old primary started
  as it was. 50 checks.
- Guide: "Two database servers": replication setup, Radiator and admin
  settings, failover, rebuilding the old primary as the standby, planned
  switchover, the replay window of asynchronous replication, and what users
  see during a failover (measured).

### Changed

- `config` for PostgreSQL adds `Timeout 2`, `ConnectTimeout` and
  `FailureBackoffTime 10`, and `connect_timeout=2` (from `PGCONNECT_TIMEOUT`)
  to a TCP `DBSource`. Radiator's defaults wait up to 60 s for a query and,
  after a failed connection, reject every login for 600 s; the test measured
  2 to 5 s for the first login after a database failure, and logins working
  again within 10 s of a promotion. Existing configurations are not changed:
  write `config` again, or add the lines by hand.

## 1.1.0 - 2026-10-12

PostgreSQL support, a migration path from SQLite, a `verify` command that
checks credentials exactly as Radiator does, and a how-to guide in which every
procedure was tested with Radiator 4.30.

### Added

- **PostgreSQL backend** (`-b pg`), for PostgreSQL 18 or later (`init` and
  `init-pg` refuse older servers):
  - `init-pg` creates an admin role that owns the database and table, and a
    Radiator login role that can read the keys but update only `accessed` and
    the counters (column-level grants). `--admin LOGIN` adds operators, and
    `--set-password` sets Radiator's password for connections over the
    network.
  - Connections use the standard libpq settings (`PGHOST`, `PGUSER`,
    `PGSSLMODE`, `PGSSLROOTCERT`, `PGSERVICE`, ...), with passwords in
    `~/.pgpass`; `-d` names the database.
  - `config` prints a `dbi:Pg` clause, using `to_timestamp(%5)` because
    Radiator's default `current_timestamp()` is not valid in PostgreSQL. For
    a remote server it includes `host`, `port`, `sslmode` and, when
    `PGSSLROOTCERT` is set, `sslrootcert`.
  - Errors are terse, so a duplicate key never prints the private ID.
- **`yubikey-db-migrate.sh`**: copies the users and keys from the SQLite
  database into PostgreSQL in one transaction.
  - Reads a consistent snapshot (`sqlite3 .backup`), so Radiator can keep
    running on SQLite; the snapshot is shredded on exit.
  - Copies counters, so previously used OTPs stay rejected, and normalizes
    rows from the old example statements (text `active` values, hex keys,
    modhex private IDs, literal `current_timestamp`), reporting each change.
    An `active` of `false`, which Radiator treated as active, becomes 0, and
    the report says those keys could log in before.
  - Verifies every row against an independent SHA-256 fingerprint of the
    snapshot and commits only if all match; `--dry-run` checks everything
    and rolls back.
  - `--mode sync`, for the cutover, adds missing keys and moves counters
    forward only, never backward; rows that differ are listed and left
    unchanged.
  - Invalid rows are listed by user and public ID (never key or private ID)
    and block the migration unless `--skip-invalid` is given.
- **`verify`**: asks for a username, static password and OTP, and checks them
  the way Radiator 4.30's `<AuthBy SQLYUBIKEY>` does with the clause from
  `config`: public ID length, `active`, the password, decryption and CRC, the
  private ID, and replay. It prints one line per check, never shows the AES
  key or private ID, and saves an accepted OTP's counters so it can't be used
  again. Values can be piped in. `--no-require2factor` matches a Radiator
  configured without `Require2Factor`. Needs `Crypt::Rijndael`.
- **`export`**: writes every record and field to CSV, with AES keys as 32 hex
  characters and private IDs in clear text, to a file created with mode 0600
  (an existing file is replaced only with `--force`) or to standard output
  with `export -`.
- **`import --from-export`** restores a file written by `export`, into either
  database: standard CSV quoting, the export header required, passwords
  stored as they are, and created, accessed and the counters restored. With
  `--replace`, counters never move backward (the database's are kept where
  they are ahead), so it also rolls a cutover back to SQLite.
- **`add --update` and `import --update`**: add new YubiKeys and update the
  ones already in the database. A YubiKey whose private ID and AES key are
  unchanged (stored as base64 or hex) gets the new username, password and
  `active` value and keeps its counters and times; one that was reprogrammed
  is replaced and its counters reset. Each updated or replaced row is
  reported.
- **`import -`** reads the CSV from standard input, for example
  `gpg -d users.csv.gpg | yubikey-db.sh import -`, also with `--from-export`.
- **`yubikey-db-user.example.sh`**: an example wrapper that adds or updates
  one test account from variables at the top of the file, sends them to
  `import --update -` through a pipe, and offers to check the record with
  `verify` (`require2factor=no` if Radiator runs without `Require2Factor`).
- **`radiator.example.conf`**: a Radiator configuration for YubiKey logins,
  to replace the package's sample, which accepts every login from 127.0.0.1.
- **`tests/make-otp.sh`**: makes the OTP of a test key, for testing without a
  YubiKey.

### Changed

- Supported platform is now Ubuntu 26.04 LTS only, with PostgreSQL 18 for
  the PostgreSQL backend. Ubuntu 24.04 and PostgreSQL 16 are not supported.
- `add` and `import` accept only 12-character public IDs, the only length
  Radiator reads from a login. Restoring an export and migrating still copy
  whatever is there.
- The comment that `config` prints above `Require2Factor` now describes what
  it does: a login may be `1234:OTP` or `1234OTP`, a user with no stored
  password is always rejected, and without it the password is optional for
  everyone.
- Internal: every database operation in `yubikey-db.sh` goes through a
  documented `db_*` backend interface (SQLite and PostgreSQL).

### Fixed

- Documentation that Radiator 4.30 contradicts: Radiator disables a key only
  when `active` is 0 or empty, so the text `true` was never rejected and the
  text `false` never disabled a key; and `Trace 4` writes every AES key and
  password hash to Radiator's log.

### Documentation

- A how-to guide, `docs/guide.md`, also published at
  <https://robert-patrick-texas.github.io/radiator-yubikey/>: how it works, a
  lab container, server installation, programming YubiKeys, SQLite,
  PostgreSQL on the Radiator server or on a separate server over TLS
  (`verify-full`, `scram-sha-256`), Radiator configuration and startup with
  systemd, adding accounts, verifying credentials, maintenance, backups, the
  SQLite-to-PostgreSQL cutover and rollback, security, troubleshooting, a
  reference, and the checks Radiator 4.30 makes on a login. Every procedure
  was run as written in containers with Radiator 4.30.
- `yubikey-db-guide.html` is generated from the guide (`docs/build-guide.sh`,
  pandoc), and `README.md` is a short front page with quick starts.

### Tests

- `tests/run-tests.sh`: 33 scenarios with golden transcripts, covering both
  backends, the migration, export and restore, `--update`, `verify` (also
  against Yubico's published sample OTP) and the example wrapper. The
  PostgreSQL scenarios need a local PostgreSQL 18 server, and the `verify`
  scenarios `openssl` and `Crypt::Rijndael`; they are skipped without them.
- `tests/radiator/run.sh`: builds a Docker image with Radiator from your own
  packages and runs 78 checks of real Radiator logins: SQLite with and
  without `Require2Factor`, PostgreSQL over the local socket and over TLS,
  the example wrapper, `radiator.example.conf`, and a cutover from SQLite to
  PostgreSQL while Radiator runs, comparing every verdict with `verify`.

## 1.0.1 - 2026-10-06

- Added `-V` / `--version` to `yubikey-db.sh`.
- Fixed the `ykman` example in the script's header comment to use slot 2,
  matching the README and HTML guide (slot 1's factory setting can't be restored).
- README and HTML guide updates made since the 1.0 package was built.
- Added version numbers to the README and HTML guide.

## 1.0 - 2026-10-01

- First release: `init`, `add`, `import`, `list`, `enable`, `disable`,
  `delete`, and `config` commands for the SQLite backend.
