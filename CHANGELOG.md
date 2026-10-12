# Changelog

## Unreleased

- Added a regression test suite: `tests/run-tests.sh` (11 scenarios).
- Internal: moved every SQLite-specific operation in `yubikey-db.sh` behind a
  documented `db_*` backend interface, as groundwork for a PostgreSQL backend.
  No change in behavior or output.
- Supported platform is now Ubuntu 26.04 LTS only. Ubuntu 24.04 and
  PostgreSQL 16 are not supported.
- PostgreSQL backend (`-b pg`), for PostgreSQL 18 or later (`init` and
  `init-pg` refuse older servers):
  - `init-pg` creates an admin role that owns the database and table, and a
    Radiator login role that can read the keys but update only `accessed` and
    the counters (column-level grants). `--admin LOGIN` adds operators.
  - Connections use the standard libpq settings (`PGHOST`, `PGUSER`,
    `PGSERVICE`, ...), with passwords in `~/.pgpass`; `-d` names the database.
  - `config` prints a `dbi:Pg` clause, using `to_timestamp(%5)` because
    Radiator's default `current_timestamp()` is not valid in PostgreSQL.
  - Errors are terse, so a duplicate key never prints the private ID.
- Tests: 7 PostgreSQL scenarios (18 in total), skipped when no server is
  reachable.

## 1.0.1 - 2026-10-06

- Added `-V` / `--version` to `yubikey-db.sh`.
- Fixed the `ykman` example in the script's header comment to use slot 2,
  matching the README and HTML guide (slot 1's factory setting can't be restored).
- README and HTML guide updates made since the 1.0 package was built.
- Added version numbers to the README and HTML guide.

## 1.0 - 2026-10-01

- First release: `init`, `add`, `import`, `list`, `enable`, `disable`,
  `delete`, and `config` commands for the SQLite backend.
