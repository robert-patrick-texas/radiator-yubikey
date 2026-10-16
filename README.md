# Radiator YubiKey Database Tools

[Latest release](https://github.com/robert-patrick-texas/radiator-yubikey/releases/latest) · [Guide](docs/guide.md) ([web version](https://robert-patrick-texas.github.io/radiator-yubikey/)) · [Changelog](CHANGELOG.md) · [MIT license](LICENSE)

Offline YubiKey one-time-password (OTP) logins for
[Radiator](https://radiatorsoftware.com/) RADIUS, with the YubiKeys in a local
**SQLite** database or a shared **PostgreSQL** database. Radiator checks each
OTP itself with Yubico's AES scheme, so no login depends on Yubico's cloud.

These scripts:

- create the database: one SQLite file, or a PostgreSQL database with an admin
  role and a Radiator role that can only update counters
- add users and YubiKeys one at a time or from a CSV file, and update them
  without resetting the counters that block replayed OTPs
- give each YubiKey a label, such as `primary, slot 1` or `spare, slot 2`,
  to tell a user's YubiKeys apart
- check a user's PIN and OTP exactly as Radiator 4.30 does (`verify`)
- list, enable, disable and delete users, and back up and restore everything
- print the matching Radiator configuration
- move an installation from SQLite to PostgreSQL while Radiator keeps running
- follow a PostgreSQL primary and standby, so Radiator keeps working on the
  standby after it is promoted
- run on three sites, with PostgreSQL under Patroni moving the primary by
  itself and no OTP lost in a failover (a tested setup in the guide)
- keep logging users in at a site that is cut off from the others, from a
  copy of the keys on its server, and copy the counters back to the primary
  when the network returns (`yubikey-partition.sh`)
- give every site one anycast address, IPv4 and IPv6, that FRR advertises
  with BGP only while the local Radiator accepts logins
  (`yubikey-anycast.sh`)
- take logins over TACACS+ as well as RADIUS, add service accounts that log
  in with a password (`svc.NAME`), and check every login against groups:
  which accounts may log in to which devices, at which TACACS+ privilege
  level, with which commands and RADIUS reply attributes
  (`radiator-groups.example.conf`)
- set up all of that on three sites from one input file: `yubikey-turnkey`
  makes, from `site.toml`, a folder for each server with a `setup.sh` that
  installs and configures everything on it, and the settings for the
  routers and the devices

The scripts come as a Debian package, `radiator-yubikey`, which puts them in
`/opt/radiator-yubikey`. `install.sh` installs it, with the packages that it
and Radiator need, after checking that Radiator is installed (from Radiator
Software's packages or from their source).

Tested with **Radiator 4.30**, **Ubuntu 26.04 LTS** and **PostgreSQL 18**
(with Patroni 4.1 and etcd 3.5 for three sites, and FRR 10.5 for anycast),
including real Radiator logins in containers (`tests/radiator/run.sh`).

## Documentation

**[docs/guide.md](docs/guide.md)** is the complete how-to: how it works, a lab
in a container, installing Radiator, programming YubiKeys, SQLite and
PostgreSQL (on the Radiator server, or a separate server over TLS),
configuring Radiator, adding accounts, verifying credentials, maintenance,
moving to PostgreSQL, two database servers with replication and failover,
three sites with automatic failover, partition mode for a site that is cut
off, one anycast address for all sites, groups and TACACS+, the turn-key
setup of all of it, security, troubleshooting, and a reference.
The same guide is published as a web page at
<https://robert-patrick-texas.github.io/radiator-yubikey/>, and
`yubikey-db-guide.html` is that page as a single file for offline use.

## Quick start: SQLite

On an Ubuntu 26.04 server, with the Radiator packages from Radiator Software
(or Radiator from their source: see
[Radiator server](docs/guide.md#radiator-server)), and the
`radiator-yubikey` package and `install.sh` from a
[release](https://github.com/robert-patrick-texas/radiator-yubikey/releases):

```bash
sudo apt install ./radiator_4.30-1_all.deb ./radiator-radius-utilxs_2.4-4.resolute_amd64.deb
rel=https://github.com/robert-patrick-texas/radiator-yubikey/releases
v=$(curl -fsSLI -o /dev/null -w '%{url_effective}' $rel/latest); v=${v##*/v}   # the latest version
curl -fLO $rel/download/v$v/radiator-yubikey_${v}_all.deb
curl -fLO $rel/download/v$v/install.sh
sudo bash install.sh            # Perl modules, SQLite and PostgreSQL tools, the scripts
cd /opt/radiator-yubikey

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

Follow the SQLite quick start, add `sudo apt install postgresql`, and replace
its `init`, `config`, `add` and `verify` lines with these (run as yourself,
not with `sudo`):

```bash
sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin "$USER"       # roles, database, table
./yubikey-db.sh -b pg config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null
sudo systemctl restart radiator
./yubikey-db.sh -b pg add
./yubikey-db.sh -b pg verify
```

For a PostgreSQL server shared by several Radiator servers, see
[PostgreSQL on a separate server](docs/guide.md#postgresql-on-a-separate-server);
for a second database server that takes over when the first fails,
[Two database servers](docs/guide.md#two-database-servers); and for a
database server on each of three sites, with automatic failover,
[Three sites](docs/guide.md#three-sites), with
[Partition mode](docs/guide.md#partition-mode) for a site that is cut off,
and to give them one address, [Anycast](docs/guide.md#anycast).

## Common tasks

| Task | Command (add `-b pg` for PostgreSQL) |
|---|---|
| List users and YubiKeys | `sudo ./yubikey-db.sh list` |
| Check a user's PIN and OTP | `sudo ./yubikey-db.sh verify -u alice` |
| Load users from CSV | `sudo ./yubikey-db.sh import --dry-run users.csv`, then without `--dry-run` |
| Change a PIN (counters kept) | `sudo ./yubikey-db.sh add --update -u alice -P vvccccbbcdef` |
| Label a YubiKey | `sudo ./yubikey-db.sh label alice vvccccbbcdeg 'spare, slot 2'` |
| Suspend a lost YubiKey | `sudo ./yubikey-db.sh disable alice vvccccbbcdef` |
| Remove a user | `sudo ./yubikey-db.sh delete alice` |
| Encrypted backup | `sudo ./yubikey-db.sh export - \| gpg -e -r backup@example.com > yubikeys.csv.gpg` |
| Move to PostgreSQL | `./yubikey-db-migrate.sh /etc/radiator/db/yubicred.db` (see [the guide](docs/guide.md#move-from-sqlite-to-postgresql)) |

## Repository

| Path | What it is |
|---|---|
| `yubikey-db.sh` | The management script (`yubikey-db.sh help` lists every option) |
| `install.sh` | Installs the `radiator-yubikey` package with the packages it and Radiator need, after checking for Radiator; `--check` changes nothing |
| `yubikey-db-migrate.sh` | Verified copy from SQLite to PostgreSQL, and counter sync for a cutover |
| `yubikey-db-user.example.sh` | Example wrapper: add or update one test account from variables |
| `radiator.example.conf` | Radiator configuration for YubiKey logins |
| `yubikey-partition.sh` | Partition mode: a copy of the keys on each server, used while it can reach no other site; with `yubikey-partition.service` and `yubikey-partition.example.conf` |
| `yubikey-anycast.sh` | Advertises the anycast addresses (through FRR) only while the local Radiator accepts logins; with `yubikey-anycast.service` and `yubikey-anycast.example.conf` |
| `users.example.csv` | Sample CSV file (test values only) |
| `VERSION` | The version, which every script reads from it (`-V` shows it) |
| `docs/guide.md` | The guide; `docs/build-guide.sh` makes `yubikey-db-guide.html` from it |
| `packaging/` | `build-deb.sh` builds the `radiator-yubikey` package (into `dist/`), from `debian/` |
| `tests/run-tests.sh` | Regression tests of the scripts against SQLite and PostgreSQL |
| `tests/radiator/` | Tests against Radiator itself, in containers (bring your own Radiator packages) |
| `tests/make-otp.sh` | Makes OTPs for test keys, for testing without a YubiKey |

## Testing

```bash
tests/run-tests.sh                           # 40 scenarios; PostgreSQL ones need a local server
tests/radiator/run.sh ~/radiator-packages    # 134 + 62 + 191 + 49 checks with real Radiator, in Docker
```

See [Testing](docs/guide.md#testing) in the guide.

## License

[MIT](LICENSE).

## References

- [Radiator reference: `<AuthBy SQLYUBIKEY>`](https://files.radiatorsoftware.com/radiator/ref/AuthBySQLYUBIKEY.html)
- [YubiKey Manager (`ykman`) documentation](https://docs.yubico.com/software/yubikey/tools/ykman/)
