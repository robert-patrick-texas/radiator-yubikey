# Changelog

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
