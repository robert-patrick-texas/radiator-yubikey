# Radiator YubiKey Database Tools

Version 1.1.0 · [Guide](docs/guide.md) ([web version](https://robert-patrick-texas.github.io/radiator-yubikey/)) · [Changelog](CHANGELOG.md)

Offline YubiKey one-time-password (OTP) logins for
[Radiator](https://radiatorsoftware.com/) RADIUS, with the YubiKeys in a local
**SQLite** database or a shared **PostgreSQL** database. Radiator checks each
OTP itself with Yubico's AES scheme, so no login depends on Yubico's cloud.

These scripts:

- create the database: one SQLite file, or a PostgreSQL database with an admin
  role and a Radiator role that can only update counters
- add users and YubiKeys one at a time or from a CSV file, and update them
  without resetting the counters that block replayed OTPs
- check a user's PIN and OTP exactly as Radiator 4.30 does (`verify`)
- list, enable, disable and delete users, and back up and restore everything
- print the matching Radiator configuration
- move an installation from SQLite to PostgreSQL while Radiator keeps running
- follow a PostgreSQL primary and standby, so Radiator keeps working on the
  standby after it is promoted

Tested with **Radiator 4.30**, **Ubuntu 26.04 LTS** and **PostgreSQL 18**,
including real Radiator logins in a container (`tests/radiator/run.sh`).

## Documentation

**[docs/guide.md](docs/guide.md)** is the complete how-to: how it works, a lab
in a container, installing Radiator, programming YubiKeys, SQLite and
PostgreSQL (on the Radiator server, or a separate server over TLS),
configuring Radiator, adding accounts, verifying credentials, maintenance,
moving to PostgreSQL, two database servers with replication and failover,
security, troubleshooting, and a reference.
The same guide is published as a web page at
<https://robert-patrick-texas.github.io/radiator-yubikey/>, and
`yubikey-db-guide.html` is that page as a single file for offline use.

## Quick start: SQLite

On an Ubuntu 26.04 server, with the Radiator packages from Radiator Software:

```bash
sudo apt install ./radiator_4.30-1_all.deb ./radiator-radius-utilxs_2.4-4.resolute_amd64.deb \
                 libauth-yubikey-decrypter-perl libcrypt-rijndael-perl libdbd-sqlite3-perl sqlite3
sudo git clone https://github.com/robert-patrick-texas/radiator-yubikey.git /opt/yubikey-db
cd /opt/yubikey-db

sudo ./yubikey-db.sh init --owner radiator:radiator                  # the database
sudo install -m 0640 -o root -g radiator radiator.example.conf /etc/radiator/radiator.conf
sudoedit /etc/radiator/radiator.conf                                 # your RADIUS clients and secrets
./yubikey-db.sh config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null
sudo systemctl enable --now radiator

sudo ./yubikey-db.sh add             # asks for the username, YubiKey values and PIN
sudo ./yubikey-db.sh verify          # asks for a PIN and an OTP, and checks them as Radiator would
```

Program each YubiKey first with
`ykman otp yubico 2 --serial-public-id --generate-private-id --generate-key`
(see [Program the YubiKeys](docs/guide.md#program-the-yubikeys)).

## Quick start: PostgreSQL on the Radiator server

Follow the SQLite quick start, but install `libdbd-pg-perl postgresql
postgresql-client` instead of `libdbd-sqlite3-perl sqlite3`, and replace its
`init`, `config`, `add` and `verify` lines with these (run as yourself, not
with `sudo`):

```bash
sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin "$USER"       # roles, database, table
./yubikey-db.sh -b pg config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null
sudo systemctl restart radiator
./yubikey-db.sh -b pg add
./yubikey-db.sh -b pg verify
```

For a PostgreSQL server shared by several Radiator servers, see
[PostgreSQL on a separate server](docs/guide.md#postgresql-on-a-separate-server),
and for a second database server that takes over when the first fails,
[Two database servers](docs/guide.md#two-database-servers).

## Common tasks

| Task | Command (add `-b pg` for PostgreSQL) |
|---|---|
| List users and YubiKeys | `sudo ./yubikey-db.sh list` |
| Check a user's PIN and OTP | `sudo ./yubikey-db.sh verify -u alice` |
| Load users from CSV | `sudo ./yubikey-db.sh import --dry-run users.csv`, then without `--dry-run` |
| Change a PIN (counters kept) | `sudo ./yubikey-db.sh add --update -u alice -P vvccccbbcdef` |
| Suspend a lost YubiKey | `sudo ./yubikey-db.sh disable alice vvccccbbcdef` |
| Remove a user | `sudo ./yubikey-db.sh delete alice` |
| Encrypted backup | `sudo ./yubikey-db.sh export - \| gpg -e -r backup@example.com > yubikeys.csv.gpg` |
| Move to PostgreSQL | `./yubikey-db-migrate.sh /etc/radiator/db/yubicred.db` (see [the guide](docs/guide.md#move-from-sqlite-to-postgresql)) |

## Repository

| Path | What it is |
|---|---|
| `yubikey-db.sh` | The management script (`yubikey-db.sh help` lists every option) |
| `yubikey-db-migrate.sh` | Verified copy from SQLite to PostgreSQL, and counter sync for a cutover |
| `yubikey-db-user.example.sh` | Example wrapper: add or update one test account from variables |
| `radiator.example.conf` | Radiator configuration for YubiKey logins |
| `users.example.csv` | Sample CSV file (test values only) |
| `docs/guide.md` | The guide; `docs/build-guide.sh` makes `yubikey-db-guide.html` from it |
| `tests/run-tests.sh` | Regression tests of the scripts against SQLite and PostgreSQL |
| `tests/radiator/` | Tests against Radiator itself, in containers (bring your own Radiator packages) |
| `tests/make-otp.sh` | Makes OTPs for test keys, for testing without a YubiKey |

## Testing

```bash
tests/run-tests.sh                           # 33 scenarios; PostgreSQL ones need a local server
tests/radiator/run.sh ~/radiator-packages    # 78 + 50 checks of real Radiator logins, in Docker
```

See [Testing](docs/guide.md#testing) in the guide.

## References

- [Radiator reference: `<AuthBy SQLYUBIKEY>`](https://files.radiatorsoftware.com/radiator/ref/AuthBySQLYUBIKEY.html)
- [YubiKey Manager (`ykman`) documentation](https://docs.yubico.com/software/yubikey/tools/ykman/)
