# YubiKey OTP on Radiator with SQLite or PostgreSQL

A how-to guide for offline YubiKey one-time-password (OTP) logins on
[Radiator](https://radiatorsoftware.com/) RADIUS, with the YubiKeys kept in a
local SQLite database or a shared PostgreSQL database, managed with the scripts
in this repository. It covers a lab you can build in a container, a server
installation, adding accounts, checking credentials, day-to-day maintenance,
moving from SQLite to PostgreSQL, a second PostgreSQL server that takes over
when the first fails, three sites with automatic failover, logins at a site
that is cut off, one anycast address for all of them, and a tool that sets
up all of that from one input file.

The scripts, this guide and the releases are on GitHub, under the
[MIT license](https://github.com/robert-patrick-texas/radiator-yubikey/blob/main/LICENSE):
<https://github.com/robert-patrick-texas/radiator-yubikey>.

Every procedure in this guide was run as written with **Radiator 4.30** on
**Ubuntu 26.04 LTS** with **PostgreSQL 18** (and Ubuntu's Patroni 4.1 and
etcd 3.5 for three sites, and FRR 10.5 for anycast), and
`tests/radiator/run.sh` repeats the checks (see [Testing](#testing)).

<!-- toc -->
## Contents

1. [How it works](#how-it-works)
2. [What you need](#what-you-need)
3. [Try it in a lab container](#try-it-in-a-lab-container)
4. [Install on the servers](#install-on-the-servers)
5. [Program the YubiKeys](#program-the-yubikeys)
6. [Create the database](#create-the-database)
7. [Configure and start Radiator](#configure-and-start-radiator)
8. [Add accounts](#add-accounts)
9. [Verify credentials](#verify-credentials)
10. [Maintain accounts](#maintain-accounts)
11. [Move from SQLite to PostgreSQL](#move-from-sqlite-to-postgresql)
12. [Two database servers](#two-database-servers)
13. [Three sites](#three-sites)
14. [Partition mode](#partition-mode)
15. [Anycast](#anycast)
16. [Groups and TACACS+](#groups-and-tacacs)
17. [Turn-key setup](#turn-key-setup)
18. [Security](#security)
19. [Troubleshooting](#troubleshooting)
20. [Reference](#reference)
21. [Testing](#testing)
22. [References](#references)
<!-- /toc -->

## How it works

Each time someone touches a YubiKey, it types a 44-character OTP. The first 12
characters are the YubiKey's **public ID**. The other 32 are a token
encrypted with an **AES key** stored in the YubiKey. The token holds the
YubiKey's **private ID** and two counters that go up with every OTP.

Radiator's `<AuthBy SQLYUBIKEY>` checks a login like this:

1. It splits what the user typed into the static password (PIN), the public
   ID and the token. Both `1234:vvccccbbcdef...` and `1234vvccccbbcdef...` work.
2. It looks up the row for that **username and public ID** in the database.
3. It decrypts the token with the AES key from that row and checks its CRC.
4. It checks that the private ID in the token matches the row
   (`CheckSecretId`).
5. It rejects the OTP unless its counters are ahead of the ones saved in the
   row, so a captured OTP can't be used twice, and then saves the new
   counters. The database refuses to save counters that don't move forward,
   so even the same OTP sent to two Radiator servers at the same moment is
   accepted only once.

Nothing is sent to Yubico. The catch is that Radiator must know each
YubiKey's AES key, and Yubico keeps the factory key secret, so **every YubiKey
is reprogrammed with an AES key you generate**, and that key is loaded into
the database.

### The scripts

| File | What it does |
|---|---|
| `yubikey-db.sh` | Creates the database, adds, updates, labels, lists, disables and deletes users and YubiKeys, checks a password and OTP (`verify`), exports and restores, manages service accounts and groups, and prints the Radiator configuration. SQLite by default, PostgreSQL with `-b pg`. |
| `install.sh` | Installs the `radiator-yubikey` package, which puts all of these in `/opt/radiator-yubikey`, with the packages that it and Radiator's YubiKey support need, after checking that Radiator is installed (see [The radiator-yubikey package](#the-radiator-yubikey-package)). |
| `yubikey-db-migrate.sh` | Copies every YubiKey from the SQLite database into PostgreSQL, verified row by row, and keeps counters in step during a cutover. |
| `yubikey-db-user.example.sh` | An example wrapper that adds or updates one test account from variables at the top of the file. |
| `radiator.example.conf` | A Radiator configuration for YubiKey logins, to replace the package's sample. |
| `radiator-groups.example.conf`, `dictionary.yubikey` | A Radiator configuration for RADIUS and TACACS+ logins, by YubiKey or service account, checked against groups (see [Groups and TACACS+](#groups-and-tacacs)), and the dictionary entry it needs. |
| `yubikey-partition.sh` | Keeps a copy of the keys on each server of the three sites, and makes Radiator use it while the server can reach no other site (see [Partition mode](#partition-mode)); with `yubikey-partition.service` and `yubikey-partition.example.conf`. |
| `yubikey-anycast.sh` | Puts the anycast addresses on the loopback interface, for FRR to advertise, only while the local Radiator accepts logins (see [Anycast](#anycast)); with `yubikey-anycast.service` and `yubikey-anycast.example.conf`. |
| `yubikey-backup.sh` | Backs up the PostgreSQL database every day, encrypted for a certificate whose key is kept elsewhere, checks and decrypts the backups, and restores one (see [Automatic backups](#automatic-backups)); with `yubikey-backup.service`, `yubikey-backup.timer` and `yubikey-backup.example.conf`. |
| `yubikey-turnkey`, `yubikey-turnkey-setup.sh`, `site.example.toml` | Make and run the setup of three sites from one input file (see [Turn-key setup](#turn-key-setup)). |
| `users.example.csv` | A sample bulk-import file (test values only). |
| `VERSION` | The scripts' version: each script reads it from this file, next to it, and shows it with `-V`. |
| `tests/make-otp.sh` | Makes the OTP a YubiKey with given values would type, for tests without a YubiKey. |
| `tests/radiator/` | Builds a container with Radiator and runs real logins against both databases. |
| `packaging/` | Builds the `radiator-yubikey` package (`packaging/build-deb.sh`). |

### SQLite or PostgreSQL?

| | SQLite | PostgreSQL |
|---|---|---|
| Where the keys are | One file on the Radiator server | A database that several Radiator servers can share |
| Several Radiator servers | Each has its own file and its own counters, so an OTP used on one server is still accepted on another | One set of counters, so an OTP works only once anywhere |
| Who can change what | Anyone who can write the file | Radiator's login can read keys and update only counters; admins are members of an admin role |
| To run | Nothing more | A PostgreSQL 18 server, on the Radiator server or elsewhere (over TLS) |
| If the database server fails | — | A second server can take over (see [Two database servers](#two-database-servers)), or with three sites, Patroni moves the primary by itself (see [Three sites](#three-sites)) |

Start with SQLite for one Radiator server. Use PostgreSQL when more than one
Radiator server checks the same YubiKeys. You can move later (see
[Move from SQLite to PostgreSQL](#move-from-sqlite-to-postgresql)).

## What you need

- **Radiator from Radiator Software**: their packages for Ubuntu 26.04, or
  their source. This guide uses the packages `radiator_4.30-1_all.deb` and
  `radiator-radius-utilxs_2.4-4.resolute_amd64.deb`. The `radiator` package
  needs no license file; a `radiator-locked` package needs
  `/etc/radiator/license.conf` from Radiator Software.
- **The `radiator-yubikey` package and `install.sh`**, from this
  repository's [releases](https://github.com/robert-patrick-texas/radiator-yubikey/releases).
- **Ubuntu 26.04 LTS** for the Radiator server and, for PostgreSQL, a
  **PostgreSQL 18** server (Ubuntu 26.04's default).
- **YubiKeys** with a free OTP slot, and
  [YubiKey Manager](https://www.yubico.com/support/download/yubikey-manager/)
  (`ykman`) on a trusted workstation to program them.
- For the lab and the automated test: **Docker**, usable without `sudo`
  (membership of the `docker` group).

| Machine | Packages |
|---|---|
| Radiator server | Radiator; `libauth-yubikey-decrypter-perl`, `libcrypt-rijndael-perl`, `libcache-fastmmap-perl`, `libdbd-sqlite3-perl` + `sqlite3` (SQLite) and `libdbd-pg-perl` + `postgresql-client` (PostgreSQL), which `install.sh` installs |
| Where you run the scripts (usually the Radiator server) | The `radiator-yubikey` package (with `perl`, and `sqlite3` or `postgresql-client`); `libcrypt-rijndael-perl` for `verify` |
| PostgreSQL server (if separate) | `postgresql` |
| Each server, for partition mode | `sqlite3`, `libdbd-sqlite3-perl` |
| Each server, for anycast | `frr` |
| Workstation that programs keys | `ykman` |

## Try it in a lab container

A lab shows the whole setup working before you touch a server, and needs no
YubiKey: `tests/make-otp.sh` makes OTPs for test keys. The container is
Ubuntu 26.04 with Radiator, SQLite and PostgreSQL 18 (and Patroni and etcd,
which only the [three-site test](#the-automated-test) uses).

### Build the lab image

Put the two Radiator packages in a directory of their own, then build the
image from the repository's `tests/radiator/Dockerfile`:

```bash
git clone https://github.com/robert-patrick-texas/radiator-yubikey.git
cd radiator-yubikey
mkdir -p ~/radiator-packages        # copy radiator_*.deb and radiator-radius-utilxs_*.deb here
docker build -t radiator-yubikey-lab -f tests/radiator/Dockerfile ~/radiator-packages
```

Start a container with the repository mounted read-only at
`/opt/radiator-yubikey`, where the package puts the scripts on a server. You
work as root inside it, so the commands below have no `sudo`:

```bash
docker run -it --rm --name yk-lab -v "$PWD:/opt/radiator-yubikey:ro" -w /opt/radiator-yubikey radiator-yubikey-lab bash
```

### SQLite in the lab

Create the database, add a test user, and install the Radiator configuration
(sections 6 to 8 explain each step):

```bash
./yubikey-db.sh init --owner radiator:radiator
./yubikey-db.sh add -u alice -P vvccccbbcdef -p 4a6f8e2d1c3b -k 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d -w 1234
./yubikey-db.sh config > /etc/radiator/conf.d/yubikey.conf
install -m 0640 -o root -g radiator radiator.example.conf /etc/radiator/radiator.conf
```

Start Radiator as the `radiator` user, the way its systemd unit does:

```bash
sudo -u radiator /opt/radiator/radiator/radiusd -foreground -no_pid_file -config_file /etc/radiator/radiator.conf &
sleep 2
```

Log in with an OTP for alice's test key (counter 1), then try the same OTP
again:

```bash
OTP=$(tests/make-otp.sh vvccccbbcdef 4a6f8e2d1c3b 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d 1)
/opt/radiator/radiator/radpwtst -s 127.0.0.1 -secret local-test-secret -auth_port 1812 -noacct -user alice -password "1234:$OTP"
/opt/radiator/radiator/radpwtst -s 127.0.0.1 -secret local-test-secret -auth_port 1812 -noacct -user alice -password "1234:$OTP"
tail -2 /var/log/radiator/authentication.log
```

The first login prints `OK`; the second prints `Rejected: Request Denied`,
and the log gives the reason, `Replay attack detected`. Check the next OTP
without Radiator, and look at the saved counters:

```bash
printf '%s\n' 1234 "$(tests/make-otp.sh vvccccbbcdef 4a6f8e2d1c3b 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d 2)" | ./yubikey-db.sh verify -u alice
./yubikey-db.sh list
```

### PostgreSQL in the lab

Start PostgreSQL, create its roles and database (root is the lab's admin),
copy alice over from SQLite, and point Radiator at PostgreSQL:

```bash
pg_ctlcluster 18 main start
sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin root
./yubikey-db-migrate.sh /etc/radiator/db/yubicred.db
./yubikey-db.sh -b pg config > /etc/radiator/conf.d/yubikey.conf
pkill -f radiusd; sleep 1
sudo -u radiator /opt/radiator/radiator/radiusd -foreground -no_pid_file -config_file /etc/radiator/radiator.conf &
sleep 2
```

The counters came along, so the OTP that `verify` used (counter 2) is
rejected, and the next one is accepted:

```bash
for n in 2 3; do
    /opt/radiator/radiator/radpwtst -s 127.0.0.1 -secret local-test-secret -auth_port 1812 -noacct -user alice \
        -password "1234:$(tests/make-otp.sh vvccccbbcdef 4a6f8e2d1c3b 6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d $n)"
done
./yubikey-db.sh -b pg list
```

### With a real YubiKey

Program a spare YubiKey as in [Program the YubiKeys](#program-the-yubikeys),
add it (the script asks for the private ID, AES key and PIN), then touch the
YubiKey when asked:

```bash
./yubikey-db.sh -b pg add -u you -P <public ID from ykman>
./yubikey-db.sh -b pg verify -u you
```

For a login through Radiator, read the OTP into a variable first, because the
YubiKey presses Enter after the OTP:

```bash
read -rsp 'PIN: ' PIN; echo; read -rp 'Touch the YubiKey: ' OTP
/opt/radiator/radiator/radpwtst -s 127.0.0.1 -secret local-test-secret -auth_port 1812 -noacct -user you -password "$PIN:$OTP"
```

Leave the container with `exit`; `--rm` deletes it.

### The automated test

`tests/radiator/run.sh` builds the same image, with Patroni, etcd and FRR
(and debhelper and lintian, to build and check the package) added, and runs
seven tests of real Radiator logins:

- `e2e.sh`, 145 checks in a throwaway container: SQLite with and without
  `Require2Factor`, PostgreSQL over the local socket and over TLS, the example
  wrapper, a user with two YubiKeys (each with its own counters, PIN and
  `active`; another user's YubiKey refused), a cutover from SQLite to
  PostgreSQL while Radiator runs, the same OTP sent twice at the same
  moment to two of Radiator's farm processes (accepted twice without the
  trigger, once with it), and a counter save on PostgreSQL whose answer is
  lost (its session ended while it waits for a standby: not answered with
  1.8.1's `UpdateQuery`, accepted with this one's), and a YubiKey stored for
  the username `DEFAULT`, which logs in no one else, and the anycast check
  renewing its key with Radiator's login over TLS, then logging in with the
  new key (Radiator refuses the old one). For each login it checks
  Radiator's answer and the reason it logs, and that `verify` agrees.
- `groups.sh`, 133 checks in a throwaway container, with
  `radiator-groups.example.conf` and devices at addresses in 127.0.0.0/8:
  logins over TACACS+ (with a small client on Radiator's own modules, and
  with Radiator's `tacacsplustest`) and RADIUS, by YubiKey and by service
  account, from devices in three device groups and from an unlisted one,
  on SQLite and then PostgreSQL. It checks each login, privilege level,
  command authorization and RADIUS reply against the groups; a login
  followed by eight authorizations at once, which several of Radiator's
  processes answer; `enable`; accounting; that a change in the groups, or a
  disabled account, applies to a session already open; and that nothing is
  allowed while PostgreSQL is stopped. It also runs the anycast check's
  `check` over RADIUS and TACACS+, set up as in
  [Set up anycast on each server](#set-up-anycast-on-each-server), step 5,
  with its service account disabled, its group's access taken away,
  another password in the database, a wrong key, a wrong port and an
  address Radiator doesn't listen on; and that its accounts can't log in
  from a device.
- `ha.sh`, 63 checks with four containers: two PostgreSQL servers (primary
  and streaming standby, over TLS) and two Radiator servers, through a dead
  primary, a hung primary, failovers, an old primary coming back, a
  planned switchover (a login held until the standby is promoted, and one
  held for 5 s, then rejected, when none is), the replay window (see
  [Two database servers](#two-database-servers)), and the same OTP sent to
  both Radiator servers at the same moment.
- `geo.sh`, 214 checks with three containers, one per site, each running
  systemd with etcd, PostgreSQL under Patroni, Radiator, FRR and
  `yubikey-anycast.sh` from the package, set up as in
  [Three sites](#three-sites) and [Anycast](#anycast), with traffic control adding the WAN delays (55 ms
  between West and East, 4 ms between the East sites). A fourth container
  stands in for West's router (FRR), and a fifth, behind it, is a RADIUS
  client that logs in at the anycast addresses, over IPv4 and IPv6. It
  measures login times, switches the primary over twice while four users at
  each site log in at the same time, then stops West's Radiator and West's
  check, reboots each server in turn, cuts West's and then the primary's
  power, kills Patroni on the primary, cuts West off, cuts the primary's
  site off, breaks the link between the East sites, copies a standby again,
  and takes two servers down at once. Then it sets up
  [partition mode](#partition-mode), has West's check renew its key under
  systemd (and West's copy get it), and cuts West off, cuts the primary's
  site off, takes two servers down at once, and breaks the link between the
  East sites again. Each time it checks which logins are accepted, which OTPs
  are replays, that the cluster recovers, which servers the router has
  anycast routes from, and which server answers the client. Last, it sets
  up the [automatic backups](#automatic-backups) with the guide's steps
  (the key pair made on the client, as the admins' machine), checks and
  decrypts one there, and restores it on the primary, at its prompt, after
  a login: the OTP stays used, and the sites go on logging users in and
  advertising. The containers have the `SYS_ADMIN` capability (for
  systemd) and `NET_ADMIN` (for traffic control and addresses in their own
  network), but aren't privileged. Docker sets the two kernel settings of
  [Set up anycast on each server](#set-up-anycast-on-each-server), step 2,
  in the containers (`--sysctl`); the step's commands themselves were run in
  a container whose kernel settings it could change for its own network
  only.
- `package.sh`, 49 checks of the package and `install.sh`: the
  package builds the same twice, lintian finds nothing in it, and it puts
  nothing outside `/opt/radiator-yubikey` but its units. Then, on fresh
  Ubuntu 26.04 containers (`apt-get` in them needs network access):
  without Radiator, where `install.sh` stops, or goes on with `--yes`; with
  Radiator Software's packages; with Radiator's source unpacked in
  `/opt/radiator/radiator`; and with it installed with `make install`
  (taken from the `radiator` package, which holds Radiator's source
  distribution). Each Radiator then accepts a login and rejects the same
  OTP again. Last, under systemd: units installed by hand as this guide
  said before the package, replaced with `install.sh`'s commands; the
  package's units (and the backups' timer) neither enabled nor started by
  the install, and found sound by `systemd-analyze verify`, restarted by
  an upgrade only while they run, stopped by a removal, and gone after a
  purge.
- `turnkey.sh`, 334 checks of [the turn-key setup](#turn-key-setup):
  `yubikey-turnkey` makes the folders from a `site.toml` with two routers
  at West's site, and `setup.sh` runs on three fresh Ubuntu 26.04
  containers (systemd and `iproute2` only) at the same time, installing
  everything with `apt-get` (it needs network access). Two more containers
  are the routers (FRR), and one behind them is a device, and the admins'
  machine. It checks the tool's output, `--check` on a fresh server, the
  cluster, the anycast checks, both routers' routes and BFD sessions;
  logins at the anycast addresses over RADIUS and TACACS+, IPv4 and IPv6,
  by YubiKey and by service account, refused for a group without access to
  the device's group and from an unlisted device (the catch-all) until its
  group has access; West withdrawn from both of its routers when only its
  TACACS+ login fails, and when its check stops; `setup.sh --status` (OK
  on all three, also without the folder; and what it says with etcd
  stopped on one server, a router down, the primary moved, West withdrawn,
  and a folder copied but not set up); the
  [backups](#turn-key-backups) (the first, made by `setup.sh`, more on a
  standby, how many it keeps, `--status` with one 30 hours old and with
  the timer stopped; one checked and decrypted on the admins' machine,
  with a key pair made as this guide says, and restored on the primary
  after a login, a deleted YubiKey, a group change and a renewed anycast
  key: what it undoes, the counters and keys it keeps, logins right after,
  and no restore on a standby); the firewall (PostgreSQL
  closed to a machine outside the admin subnets, Patroni's REST API open
  to the admins); `setup.sh` run again (nothing installed or restarted); a
  reboot; a new device added in `site.toml`; new certificates, one server
  at a time (etcd, Patroni and PostgreSQL present them); servers rebuilt
  with the same names and addresses (West, whose check renewed its key,
  and East1, lost while it was the primary, on new containers, with
  logins going on meanwhile, the database's key and counter for the
  check, and the primary moved back; East2 started over in place with
  `--reset`), `setup.sh` stopping at etcd while East2's is stopped, and
  joining when all three's was; two servers lost (East1 and East2: logins
  through West from its copy, `setup.sh --alone` on West, the two set up
  again at the same time, the OTP used on West alone refused after);
  `--reset` on all three, then `setup.sh` again, and the last backup
  restored into the new cluster; and servers replaced (West moved to new
  addresses, its `--check` warning before the other two knew it, and
  East1, lost while it was the primary, replaced by a server of a new name
  and addresses, which then becomes the primary); and new passwords and
  keys (`--rotate`: a standby run first waits for the primary, logins
  every second all along, replication with the new password, a
  switchover, the admin's old and new passwords and their own kept, a
  device's new TACACS+ key).

- `upgrade.sh`, 59 checks of [upgrades](#upgrade-a-turn-key-setup), in
  `turnkey.sh`'s lab: three servers set up with radiator-yubikey 1.12.0
  (its `yubikey-turnkey` and package, from the git tag `v1.12.0`), then
  upgraded to this version (built from the working tree, as `1.12.0.1`
  if `VERSION` is still `1.12.0`), the primary first, with `--status`
  OK after; a newer Radiator (4.30-1 again, as 4.30-1+lab1, with a changed
  sample `radiator.conf`: the server's stays) on each; and PostgreSQL
  updated on each with `needrestart` installed (the standbys, a
  switchover, the old primary), and on the primary without the
  switchover, which fails over. A TACACS+ login every second all along.

```bash
tests/radiator/run.sh ~/radiator-packages                   # all seven, about 65 minutes
tests/radiator/run.sh ~/radiator-packages ha                # only ha.sh (or e2e, groups, geo, package, turnkey, or upgrade)
tests/radiator/run.sh ~/radiator-packages turnkey upgrade   # these two
```

Each prints one `PASS` or `FAIL` line per check and ends with a count, such as
`Radiator 4.30-1: 145 passed, 0 failed` (and `133 passed` for `groups.sh`),
`Two database servers: 63 passed, 0 failed`,
`Three sites: 214 passed, 0 failed`,
`Package: 49 passed, 0 failed`, `Turnkey: 334 passed, 0 failed` and
`Upgrade: 59 passed, 0 failed`. Run them again with each new
Radiator version. `KEEP=1 tests/radiator/ha.sh yk-radiator-test:4.30-1` (or
`geo.sh`) leaves the containers running afterwards, to look around.
`run.sh` stops a lab after about twice its usual time (60 minutes for
`turnkey.sh`, 30 for `geo.sh`) and says so, and goes on with the next; the
lab removes its containers as it stops. In `turnkey.sh` and `upgrade.sh`,
`setup.sh` waits at most 5 minutes for the other servers
(`TURNKEY_WAIT=300`), not 30, so one that hangs fails within minutes.

## Install on the servers

### Radiator server

Install Radiator first. It comes from Radiator Software, as packages or as
source, and the scripts work with either.

**Radiator Software's packages**, as this guide uses:

```bash
sudo apt install ./radiator_4.30-1_all.deb ./radiator-radius-utilxs_2.4-4.resolute_amd64.deb
```

The package creates the `radiator` user, installs Radiator in
`/opt/radiator/radiator` (its tools, such as `radpwtst`, aren't on the
`PATH`), and adds the `radiator.service` systemd unit, which runs Radiator as
`radiator` with `/etc/radiator/radiator.conf`.

**Radiator's source**: unpacked in `/opt/radiator/radiator`, where the
systemd unit in its `goodies` directory runs it, or installed with
`perl Makefile.PL && make && sudo make install` (as its `Makefile.PL`
says), which puts `radiusd` and `radpwtst` in `/usr/local/bin`. Then make
what the package would have made: the `radiator` user, Radiator's
directories, and the systemd unit (for a `make install`, with its
`/opt/radiator/radiator` paths changed to where `radiusd` is):

```bash
sudo groupadd -r radiator
sudo useradd -r -g radiator -d /var/lib/radiator -s /usr/sbin/nologin radiator
sudo install -d /etc/radiator/conf.d
sudo install -d -o radiator -g radiator /var/log/radiator /var/lib/radiator
sudo install -m 0644 goodies/radiator.service /etc/systemd/system/   # in the source directory
```

Where this guide runs `/opt/radiator/radiator/radiusd` or `radpwtst`, run
yours. After a `make install`, give `radpwtst` the source's dictionary
(`-dictionary /usr/src/radiator/dictionary`, for example), and in
[Install the configuration](#install-the-configuration), set
`DictionaryFile` to it too.

### The radiator-yubikey package

The scripts come as a package, `radiator-yubikey`, which puts them in
`/opt/radiator-yubikey`, and `install.sh`, which installs the package with
the packages that it and Radiator's YubiKey support need. Download both from
a [release](https://github.com/robert-patrick-texas/radiator-yubikey/releases)
into one directory, and run `install.sh` there:

```bash
rel=https://github.com/robert-patrick-texas/radiator-yubikey/releases
v=$(curl -fsSLI -o /dev/null -w '%{url_effective}' $rel/latest); v=${v##*/v}   # the latest version
curl -fLO $rel/download/v$v/radiator-yubikey_${v}_all.deb
curl -fLO $rel/download/v$v/install.sh
sudo bash install.sh
```

The second line finds the latest release's version, such as `1.8.0`; for
another release, set `v` to its version instead.

`install.sh`:

1. Looks for Radiator: Radiator Software's `radiator` (or `radiator-locked`)
   package, or a `radiusd` from their source with Radiator's Perl modules, in
   `/opt/radiator/radiator` or on the `PATH` (give another one with
   `--radiusd FILE`). Radiator isn't a dependency of the package, so that
   either kind works. When it finds neither, it says how to install
   Radiator, and asks whether to go on without it; with no terminal to ask
   on, it stops (exit status 3), unless you give `--yes`. Without Radiator,
   the scripts still manage a database, for example on a server that only
   holds the database.
2. Installs with `apt-get`: `libauth-yubikey-decrypter-perl` and
   `libcrypt-rijndael-perl` (Radiator's YubiKey support),
   `libcache-fastmmap-perl` (for `DupCache shared` in
   `radiator.example.conf`), `libdbd-sqlite3-perl`, `sqlite3`,
   `libdbd-pg-perl`, `postgresql-client`, and the package. A package of the
   version that is installed already is left as it is.
3. Checks that Radiator's Perl loads Radiator's SQLYUBIKEY module and the
   modules it needs, and lists what is left to do: for Radiator from source,
   a missing `radiator` user or `radiator.service`; for units installed by
   an earlier version of this guide, how to use the package's instead (see
   [After upgrading the scripts](#after-upgrading-the-scripts)).

`sudo /opt/radiator-yubikey/install.sh --check` changes nothing, shows what
is installed, and exits 0 only when nothing is missing or left to do:

```text
install.sh 1.12.1
Radiator:  4.30-1, Radiator Software's package radiator (with radiator-radius-utilxs 2.4-4): /opt/radiator/radiator/radiusd
Package:   radiator-yubikey 1.12.1, installed

Packages:
  ok       libauth-yubikey-decrypter-perl 0.07-2.1
  ok       libcrypt-rijndael-perl 1.16-1build6
  ok       libcache-fastmmap-perl 1.60-1
  ok       libdbd-sqlite3-perl 1.78-1
  ok       sqlite3 3.46.1-9ubuntu0.3
  ok       libdbd-pg-perl 3.18.0-4
  ok       postgresql-client 18+290ubuntu1

Radiator's Perl (/usr/bin/perl) loads:
  ok       Radius::AuthSQLYUBIKEY   (Radiator)
  ok       Auth::Yubikey_Decrypter  (libauth-yubikey-decrypter-perl)
  ok       Crypt::Rijndael          (libcrypt-rijndael-perl)
  ok       Cache::FastMmap          (libcache-fastmmap-perl)
  ok       DBD::SQLite              (libdbd-sqlite3-perl)
  ok       DBD::Pg                  (libdbd-pg-perl)

Nothing is missing.
```

The package puts the scripts, their examples, `tests/make-otp.sh`, this
guide (`yubikey-db-guide.html`), the README and the changelog in
`/opt/radiator-yubikey`. It also installs the systemd units
`yubikey-partition.service` and `yubikey-anycast.service`, for
[Partition mode](#partition-mode) and [Anycast](#anycast), and
`yubikey-backup.service` with `yubikey-backup.timer`, for
[Automatic backups](#automatic-backups), but enables and starts none of
them.

The examples in this guide run from `/opt/radiator-yubikey`
(`cd /opt/radiator-yubikey`). With SQLite, run the scripts with `sudo`,
because the database belongs to `radiator`. With PostgreSQL, run them as
yourself, as a member of the admin role (set up in
[Create the database](#create-the-database)); `export DB_BACKEND=pg` in your
`~/.profile` saves typing `-b pg` every time.

**To upgrade**, run the new release's `install.sh` with its package, the
same way, then see [After upgrading the scripts](#after-upgrading-the-scripts).
The services that run (`yubikey-partition`, `yubikey-anycast`) restart with
the new scripts; one that you stopped stays stopped. While `yubikey-anycast`
restarts, the server's anycast addresses are off `lo` for 5 to 10 s, and the
routers send RADIUS to another site.

**To remove** the scripts, `sudo apt remove radiator-yubikey`: it stops the
two services and removes `/opt/radiator-yubikey`. The database, and
Radiator's configuration and the settings in `/etc/radiator`, stay.

**Without the package**, clone the repository to the same place; its
`install.sh` then installs the other packages only:

```bash
sudo git clone https://github.com/robert-patrick-texas/radiator-yubikey.git /opt/radiator-yubikey
cd /opt/radiator-yubikey
sudo ./install.sh
```

For partition mode, anycast and the backups, install their units yourself:
`sudo install -m 0644 yubikey-partition.service yubikey-anycast.service yubikey-backup.service yubikey-backup.timer /etc/systemd/system/`,
then `sudo systemctl daemon-reload`. To build the package from a clone, see
[`packaging/build-deb.sh`](#packagingbuild-debsh).

### PostgreSQL server

On the server that will hold the database (the Radiator server itself, or a
separate one):

```bash
sudo apt install postgresql
```

## Program the YubiKeys

Do this once for each YubiKey, on a trusted workstation. The command
overwrites OTP slot 2, which types an OTP on a long touch (slot 1 is the short
touch).

> [!WARNING]
> Slot 1's factory configuration can't be restored. After you reprogram it,
> the key no longer works with services that check OTPs through YubiCloud.
> Use slot 2 unless you're sure.

```bash
ykman otp yubico 2 --serial-public-id --generate-private-id --generate-key
```

`ykman` shows three values. Record them for this user:

| ykman output | `yubikey-db.sh` option | CSV column | Format |
|---|---|---|---|
| Public ID | `-P` | `public_id` | 12 modhex characters (only `cbdefghijklnrtuv`) |
| Private ID | `-p` | `private_id` | 12 hex characters |
| Secret key | `-k` | `aes_key` | 32 hex characters |

If a user gets more than one YubiKey, also note which is which, and the
slot, for example `primary, slot 2` and `spare, slot 2`: store that as the
YubiKey's label (`-l`, or the CSV column `label`), which `list` shows.

> [!CAUTION]
> Do **not** add `--upload`: it sends the key to Yubico.

To choose the public ID yourself, replace `--serial-public-id` with
`--public-id <12 modhex characters>`. Radiator accepts only 12-character
public IDs.

## Create the database

### SQLite

```bash
sudo ./yubikey-db.sh init --owner radiator:radiator
```

This creates `/etc/radiator/db/yubicred.db` (use `-d FILE` for another path).
Radiator writes to the database after every login, and SQLite writes a
journal file next to it, so `--owner` gives the `radiator` user the file
**and** its folder. `init` is safe to run again.

### PostgreSQL on the Radiator server

Create the roles and the database as the `postgres` superuser, and make
yourself an admin:

```bash
sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin "$USER"
```

This creates:

- the database `yubikey` (`-d NAME` for another name), with the `yubikeys`
  table;
- the role `yubikey_admin`, which owns them; `--admin LOGIN` makes a login a
  member, and you can repeat it;
- the role `radiator`, Radiator's login. It can read the lookup columns and
  update only the counters and the access time.

Radiator connects over the local socket, where Ubuntu's PostgreSQL uses peer
authentication: the `radiator` OS user logs in as the `radiator` role with no
password. Admins log in the same way as themselves.

### PostgreSQL on a separate server

Radiator then connects over the network, with TLS and a password. Below, the
database server is `db.example.com`, the Radiator server `192.0.2.21`, and the
admin `opsadmin` works on the Radiator server.

**On the database server:**

1. Install a TLS certificate for the name Radiator connects to. Use your own
   CA if you have one. For a lab, make a CA and a certificate:

   ```bash
   openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=YubiKey DB CA" -keyout ca.key -out ca.crt
   openssl req -newkey rsa:3072 -nodes -subj "/CN=db.example.com" -addext "subjectAltName=DNS:db.example.com" \
           -keyout server.key -out server.csr
   openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 -copy_extensions copy -out server.crt
   sudo install -m 0644 -o postgres -g postgres server.crt /etc/postgresql/18/main/server.crt
   sudo install -m 0600 -o postgres -g postgres server.key /etc/postgresql/18/main/server.key
   ```

   Keep `ca.key` offline. Radiator's server needs only `ca.crt`.

2. Make PostgreSQL listen on the network with that certificate:

   ```bash
   sudo tee /etc/postgresql/18/main/conf.d/yubikey.conf >/dev/null <<'EOF'
   listen_addresses = '*'
   ssl = on
   ssl_cert_file = '/etc/postgresql/18/main/server.crt'
   ssl_key_file = '/etc/postgresql/18/main/server.key'
   EOF
   ```

3. Allow `radiator` and `opsadmin` from the Radiator server, over TLS only.
   Add these lines to `/etc/postgresql/18/main/pg_hba.conf` **above** the
   first line that starts with `host`:

   ```text
   hostssl  yubikey  radiator  192.0.2.21/32  scram-sha-256
   hostssl  yubikey  opsadmin  192.0.2.21/32  scram-sha-256
   ```

   Then `sudo systemctl restart postgresql`, and open TCP port 5432 to
   `192.0.2.21` in any firewall.

4. Create the roles and the database, set Radiator's password (it asks for
   it), and give the admin a password:

   ```bash
   sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin opsadmin --set-password
   sudo -u postgres psql -c '\password opsadmin'
   ```

   This needs the scripts on the database server too, only for this step.

**On the Radiator server**, as `opsadmin`:

1. Install the CA certificate where Radiator and the admins can read it:

   ```bash
   sudo install -m 0644 ca.crt /etc/radiator/pg-ca.crt
   ```

2. Tell `psql` and the scripts where the database is, and store the password
   (`~/.pgpass` must be mode `0600`):

   ```bash
   cat >> ~/.profile <<'EOF'
   export PGHOST=db.example.com PGUSER=opsadmin PGSSLMODE=verify-full PGSSLROOTCERT=/etc/radiator/pg-ca.crt
   export DB_BACKEND=pg
   EOF
   (umask 077; echo 'db.example.com:5432:yubikey:opsadmin:YOUR-PASSWORD' >> ~/.pgpass)
   . ~/.profile
   ./yubikey-db.sh list
   ```

   `list` shows an empty table when everything works. `verify-full` checks
   that the server's certificate is for `db.example.com` and signed by your
   CA.

With these settings, `./yubikey-db.sh config` writes the same connection into
Radiator's configuration: `host`, `port`, `sslmode=verify-full` and
`sslrootcert`, and `connect_timeout=2`. You add Radiator's password in the
next section. For a second database server that takes over when this one
fails, see [Two database servers](#two-database-servers).

## Configure and start Radiator

### Install the configuration

The Radiator package's sample `/etc/radiator/radiator.conf` is for a first
test only.

> [!CAUTION]
> The sample `radiator.conf` **accepts every login from 127.0.0.1** without a
> password check, and accepts requests from **any** client that uses the
> secret `mysecret`. If you add the YubiKey clause to it, a test with
> `radpwtst` on the server succeeds without ever reaching the database.
> Replace it.

Install `radiator.example.conf` in its place, then set your RADIUS clients:

```bash
sudo cp -p /etc/radiator/radiator.conf /etc/radiator/radiator.conf.orig
sudo install -m 0640 -o root -g radiator radiator.example.conf /etc/radiator/radiator.conf
sudoedit /etc/radiator/radiator.conf
```

In the editor, change the `Secret` of `<Client 127.0.0.1>` (used for tests on
the server), and replace the `<Client 192.0.2.10>` example with one block per
RADIUS client (VPN gateway, switch, wireless controller), each with its own
long random secret.

`radiator.example.conf` runs four Radiator processes (`FarmSize 4`). Each
answers one request at a time, so one slow database query, for example
while a database server fails over, no longer holds up every other login.
`DupCache shared` lets the processes recognize a request that a RADIUS
client sent again to another process; it needs `libcache-fastmmap-perl`
(installed above) and keeps a file of about 290 MB at
`/var/lib/radiator/dupcache` while Radiator runs.

Write the YubiKey clause from `yubikey-db.sh config` to
`/etc/radiator/conf.d/yubikey.conf`, which `radiator.conf` includes. Create
the file first, so it is readable only by root and `radiator`; `tee` keeps
that owner and mode:

```bash
sudo touch /etc/radiator/conf.d/yubikey.conf
sudo chown root:radiator /etc/radiator/conf.d/yubikey.conf
sudo chmod 0640 /etc/radiator/conf.d/yubikey.conf
./yubikey-db.sh config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null          # SQLite
./yubikey-db.sh -b pg config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null    # PostgreSQL
```

For PostgreSQL on a separate server, also put Radiator's password on the
`DBAuth` lines (`sudoedit /etc/radiator/conf.d/yubikey.conf`): one in each
clause, `YubiKeySQL`, `ServiceAccounts` and `GroupAccess`. This is why the
file must not be readable by other users.

The clause it writes, for SQLite:

```apache
<AuthBy SQLYUBIKEY>
    Identifier   YubiKeyLocal
    DBSource     dbi:SQLite:dbname=/etc/radiator/db/yubicred.db
    DBUsername
    DBAuth
    AuthSelect   select secret, active, userId, counter, low, high, password from yubikeys where username=%0 and tokenId=%3
    UpdateQuery  update yubikeys set accessed=datetime(%5,'unixepoch'), counter=%0, low=%1, high=%2 where username=%3 and tokenId=%7
    Require2Factor
    CheckSecretId
    NoDefault
</AuthBy>
```

- `AuthSelect` finds the row by both the username and the public ID, so a
  user can have several YubiKeys and one user's YubiKey can't log in as
  another user.
- `UpdateQuery` saves the counters after each login. For PostgreSQL it uses
  `to_timestamp(%5)`, because Radiator's default `current_timestamp()` isn't
  valid there, and it names the login with `set_config`, so that the same
  login may save the same counters again (see
  [Database layout](#database-layout)).
- `CheckSecretId` checks the private ID inside the OTP against the database.
- `NoDefault`: never fall back to a user called `DEFAULT`, as some Radiator
  clauses do for a user they don't find. Radiator's YubiKey clauses already
  don't, by default; the line keeps it so.
- `Require2Factor`: see below.
- For PostgreSQL, `config` also writes `Timeout 2`, `ConnectTimeout` and
  `FailureBackoffTime 2`, so Radiator gives up quickly on a database server
  that doesn't answer and tries again after 2 s, not 600 s, and hooks that
  hold a login for a few seconds while the primary changes (see
  [Configure Radiator for two servers](#configure-radiator-for-two-servers)).
  The YubiKey clause is then `YubiKeySQL`, and `YubiKeyLocal`, the name the
  Handlers use, is a group of two clauses: `YubiKeyConnect`, which connects
  to the database first, then `YubiKeySQL`.

### Choose: PIN and OTP, or OTP only

| `Require2Factor` | Users with a PIN | Users without a PIN |
|---|---|---|
| Set (as `config` writes it) | Must type `PIN:OTP` or `PINOTP` | **Always rejected** |
| Removed | May type just the OTP: the PIN is checked only if they type one | Type just the OTP |

Keep `Require2Factor` and give every user a PIN, unless you've decided on
OTP-only logins for everyone. Without it, the PIN is **optional** even for
users who have one. If you remove it, also use `verify --no-require2factor`
(and `require2factor=no` in the example wrapper), so their checks match
Radiator.

### Check and start

Check the configuration as the `radiator` user, then look at the end of the
log:

```bash
sudo -u radiator /opt/radiator/radiator/radiusd -c -foreground -no_pid_file -config_file /etc/radiator/radiator.conf
sudo tail -n 5 /var/log/radiator/radiator.log
```

Fix anything reported as `ERR` or `WARNING`; `radiusd -c` exits with 0 even
then.

> [!IMPORTANT]
> Run `radiusd` checks as `radiator`, never as root. Run as root, it creates
> `/var/log/radiator/radiator.log` owned by root, and the service can then no
> longer write its log (`Log could not append ... Permission denied`). If
> that happened, `sudo chown radiator:radiator /var/log/radiator/*`.

Start Radiator now and at every boot, and check it's running:

```bash
sudo systemctl enable --now radiator
systemctl status radiator
```

After each change to the configuration, `sudo systemctl restart radiator`. If
a firewall runs on the server, allow RADIUS from each client, for example
`sudo ufw allow from 192.0.2.10 to any port 1812 proto udp`.

Radiator logs to `/var/log/radiator/radiator.log`, and each login, with the
reason for a reject, to `/var/log/radiator/authentication.log`. Only root and
`radiator` can read them, so use `sudo` to read them.

## Add accounts

A row in the database is one YubiKey of one user. A user can have several
YubiKeys: Radiator finds the right one by the public ID at the start of the
OTP, and a **label** such as `primary, slot 1` or `spare, slot 2` tells them
apart for you (Radiator never reads it). Each command below is for SQLite;
add `-b pg` (or set `DB_BACKEND=pg`) for PostgreSQL, and leave out `sudo`
there.

### One account

`add` asks for each value you leave out; the private ID, AES key and PIN
aren't shown as you type. Press Enter at the label prompt for none:

```bash
sudo ./yubikey-db.sh add                              # asks for everything
sudo ./yubikey-db.sh add -u alice -P vvccccbbcdef     # asks for the private ID, key, PIN and label
sudo ./yubikey-db.sh add -u alice -P vvccccbbcdeg -l 'spare, slot 2'
sudo ./yubikey-db.sh add -u kiosk -P vvccccbbcdeh --no-password -l ''
```

PINs are stored as salted SHA-512 `{crypt}` hashes. Options `-k` (AES key)
and `-w` (PIN) also exist, but other users can see them in `ps` and they stay
in your shell history, so let the script ask instead.

If the YubiKey may already be in the database, add `--update` (see
[Update and replace](#update-and-replace)).

### Many accounts from a CSV file

```csv
username,public_id,private_id,aes_key,password,active,label
alice,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,1234,1,primary slot 1
alice,vvccccbbcdeg,1b2c3d4e5f60,8a7b6c5d4e3f2a1b0c9d8e7f6a5b4c3d,1234,1,spare slot 2
bob,vvccccbbcdeh,9e8d7c6b5a41,0f1e2d3c4b5a69788796a5b4c3d2e1f0,5678,yes
```

| Column | Required | Format |
|---|---|---|
| `username` | Yes | The RADIUS login name: letters, digits and `. _ @ + -` |
| `public_id` | Yes | 12 modhex characters |
| `private_id` | Yes | 12 hex characters (12 modhex characters are converted to hex) |
| `aes_key` | Yes | 32 hex characters; spaces and colons are removed |
| `password` | No | The PIN; empty for none |
| `active` | No | `1`/`0`, `true`/`false`, `yes`/`no`; default `1` |
| `label` | No | A description of the YubiKey, up to 255 characters; empty for none |

The header row is optional; blank lines and lines starting with `#` are
skipped; Windows line endings are accepted; spaces and double quotes around
a field are removed; **fields can't contain commas** (use the `label`
command for a label with a comma). Files without the `label` column, as
earlier versions wrote them, still load.

```bash
chmod 600 users.csv                                  # it holds AES keys
sudo ./yubikey-db.sh import --dry-run users.csv      # check every row; changes nothing
sudo ./yubikey-db.sh import users.csv
shred -u users.csv
```

Every row is checked first, and if any is invalid, nothing is imported
(`--skip-invalid` loads the valid rows). Valid rows are loaded in one
transaction: all of them or none. Use `-` to read the CSV from standard
input, for example from an encrypted file:
`gpg -d users.csv.gpg | sudo ./yubikey-db.sh import -`.

### A test account from a script

`yubikey-db-user.example.sh` adds or updates one account from variables at the
top of a copy of it, which suits test accounts you set up again and again. It
sends the values to `import --update -` through a pipe, so they never appear
in `ps` or a temporary file, shows the account, and then asks you to touch the
YubiKey to run `verify`.

```bash
install -m 0700 yubikey-db-user.example.sh ~/yk-user.sh   # your copy will hold an AES key
nano ~/yk-user.sh       # set cred_username, cred_password, cred_publicid, cred_privateid, cred_secret,
                        # cred_label if you want one, and db_backend, db_name and require2factor
                        # if not the defaults
sudo ~/yk-user.sh       # SQLite; for PostgreSQL run it as yourself
shred -u ~/yk-user.sh   # when done
```

The YubiKey's public ID decides which record is meant; other YubiKeys of the
user are left alone. The PIN can't contain a comma, start or end with a space,
or be in double quotes, and the label can't contain a comma. An empty
`cred_label` keeps the label the YubiKey already has.

## Verify credentials

### Check the database: `verify`

`verify` asks for a username, PIN and OTP and checks them the way Radiator
4.30 does, without Radiator, so it separates "the database is wrong" from
"Radiator is misconfigured":

```bash
sudo ./yubikey-db.sh verify
```

```text
Username: alice
Static password/PIN (Enter for none):
YubiKey OTP (touch the YubiKey): vvccccbbcdefvbvkiggllhvureilrdbnvklrcfivibet
Checking alice with YubiKey vvccccbbcdef in /etc/radiator/db/yubicred.db (Require2Factor on):
  active:           yes
  static password:  matches
  OTP:              decrypts with the stored AES key
  private ID:       matches
  replay check:     passed (OTP counter 3, session 1; stored counter 0, session 0)
Accepted. The OTP's counters were saved, so it cannot be used again.
```

Each line is one check, so a failure says what to fix: a `WRONG` PIN, an OTP
that doesn't decrypt (the database has a different AES key from the
YubiKey), a private ID that doesn't match, or a replayed OTP. It never shows
the AES key or private ID. When the YubiKey has a label, a first line
`label:` shows it, so you can see which of the user's YubiKeys was used. An
accepted OTP's counters are saved, as Radiator saves them.

- `-u USER` gives the username. `--no-require2factor` matches a Radiator
  without `Require2Factor`.
- Without a terminal, it reads the username (unless `-u` is given), the PIN
  and the OTP from standard input, one per line:
  `printf '%s\n' "$pin" "$otp" | ./yubikey-db.sh verify -u alice`.
- It exits with 0 if Radiator would accept the login, 1 if not.

### Check the whole path: `radpwtst`

`radpwtst` sends a real RADIUS request, so it also tests Radiator's
configuration. On the Radiator server, with the secret of
`<Client 127.0.0.1>`:

```bash
read -rsp 'PIN: ' PIN; echo; read -rp 'Touch the YubiKey: ' OTP
/opt/radiator/radiator/radpwtst -s 127.0.0.1 -secret local-test-secret -auth_port 1812 -noacct -user alice -password "$PIN:$OTP"
sudo tail -n 1 /var/log/radiator/authentication.log
```

It prints `OK`, or `Rejected: Request Denied` with the reason in the log.
Send the same OTP again: it must be rejected with `Replay attack detected`.
Without a YubiKey, make the OTP of a test key with `tests/make-otp.sh` (see
the lab). `-auth_port 1812` matters: `radpwtst` uses port 1645 by default.

Finally, log in through a real RADIUS client: users type their PIN and then
touch the YubiKey, in the password field.

## Maintain accounts

Add `-b pg` for PostgreSQL. `list` never shows AES keys or PINs; it shows
each YubiKey's public ID, `active`, times, counter and label.

| Task | Command |
|---|---|
| List all users and YubiKeys | `sudo ./yubikey-db.sh list` |
| Show one user | `sudo ./yubikey-db.sh list alice` |
| Check a user's PIN and OTP | `sudo ./yubikey-db.sh verify -u alice` |
| Change a PIN (counters kept) | `sudo ./yubikey-db.sh add --update -u alice -P vvccccbbcdef` |
| Give a user another YubiKey | `sudo ./yubikey-db.sh add -u alice -P vvccccbbcdeg -l 'spare, slot 2'` |
| Label a YubiKey, or change its label | `sudo ./yubikey-db.sh label alice vvccccbbcdeg 'spare, slot 2'` |
| Remove a YubiKey's label | `sudo ./yubikey-db.sh label alice vvccccbbcdeg ''` |
| Suspend a user (all their YubiKeys) | `sudo ./yubikey-db.sh disable alice` |
| Suspend one lost YubiKey | `sudo ./yubikey-db.sh disable alice vvccccbbcdef` |
| Turn a user back on | `sudo ./yubikey-db.sh enable alice` |
| Remove one YubiKey | `sudo ./yubikey-db.sh delete alice vvccccbbcdef` |
| Remove a user | `sudo ./yubikey-db.sh delete alice` |
| Back up every YubiKey, encrypted | `sudo ./yubikey-db.sh export - \| gpg -e -r backup@example.com > yubikeys.csv.gpg` |
| Restore a backup | `gpg -d yubikeys.csv.gpg \| sudo ./yubikey-db.sh import --from-export -` |

### Update and replace

`add` and `import` refuse a YubiKey that is already in the database. Two
options change that:

| | `--update` | `--replace` |
|---|---|---|
| Same YubiKey (same public ID, private ID and AES key) | Username, PIN and `active` updated; **counters and times kept** | Replaced; counters reset to 0 |
| Reprogrammed YubiKey (same public ID, new private ID or AES key) | Replaced; counters reset to 0 | Replaced; counters reset to 0 |
| New YubiKey | Added | Added |
| Label | The one given; without one, the YubiKey's label is kept | The one given; without one, the YubiKey's label is kept |

Use `--update` to change a PIN or move a YubiKey to another user: resetting
the counters would let OTPs that were already used be accepted again. Use
`--replace` only after programming the **same** values into a YubiKey again
(for example into a replacement YubiKey), because the YubiKey's own counters
then start again from 0. Each updated or replaced row is reported.

### A lost or stolen YubiKey

1. Disable it at once: `sudo ./yubikey-db.sh disable alice vvccccbbcdef`.
   Logins are checked only against this database, so nothing needs revoking
   at Yubico.
2. When it won't come back, delete it:
   `sudo ./yubikey-db.sh delete alice vvccccbbcdef`.
3. Program a new YubiKey and add it.

### Backups

`export` writes every row and field to CSV, with AES keys as 32 hex
characters, and `import --from-export` loads it into either database.

```bash
sudo ./yubikey-db.sh export - | gpg -e -r backup@example.com > yubikeys-$(date +%F).csv.gpg
gpg -d yubikeys-2026-10-12.csv.gpg | sudo ./yubikey-db.sh import --from-export --dry-run -
gpg -d yubikeys-2026-10-12.csv.gpg | sudo ./yubikey-db.sh import --from-export --replace -
```

A restore brings back PINs (as stored), times and counters. With `--replace`
it overwrites existing rows but **never moves counters backward**, so an old
backup can't make used OTPs valid again. `export FILE` writes a file with
mode `0600` instead, and refuses to overwrite one unless you add `--force`.

You can also back up the database itself: for SQLite,
`sudo sqlite3 /etc/radiator/db/yubicred.db ".backup '/root/yubicred-backup.db'"`
takes a consistent copy while Radiator runs; for PostgreSQL,
`yubikey-backup.sh` makes one every day (see
[Automatic backups](#automatic-backups)). Only such a backup holds the
[service accounts and groups](#groups-and-tacacs) too. Every backup holds
every AES key: keep it encrypted.

### Automatic backups

For PostgreSQL, `yubikey-backup.sh` backs up the whole database every day
on each database server: the YubiKeys, the service accounts and the
groups.

- **From the server's own PostgreSQL.** `pg_dump` reads the local
  database, a standby's too, so each server of two or three keeps its own
  backups.
- **Encrypted for a key that isn't on the servers.** The dump goes
  straight into `openssl cms`: AES-256-GCM, with a new key for each file,
  wrapped with RSA-OAEP for a certificate whose private key you keep
  elsewhere. It is never on disk in clear, and a copy of a backup is of no
  use without the key.
- **Kept on the server.** `/var/backups/yubikey-db.cms.0` is the newest:
  each run moves the others up one (`.0` to `.1`, `.1` to `.2`, ...), and
  keeps 7 (`.0` to `.6`; `KEEP` sets how many). They are mode `0640`,
  group `adm`, so an admin in that group can fetch them.
- **Checked and restored with the same script.** `check` decrypts a
  backup and reads it back whole, and `decrypt` writes the dump, on any
  machine with `openssl` and `pg_restore`, and only when the file is whole
  and unchanged (`openssl` alone writes out what it decrypted even then).
  `restore`, on the primary, says what it would undo and asks first.

**1. Make the key pair** on an admin's machine, not on a server:

```bash
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -aes-256-cbc -out backup.key
openssl req -new -x509 -key backup.key -days 7300 -subj "/CN=yubikey backups" -out backup.crt
```

`openssl` asks for a passphrase for the key (twice), and for it again to
sign the certificate. Keep `backup.key` in two places, apart from each
other and from the servers (two USB drives in two safes, say), and the
passphrase on its own (a password manager): whoever has both can read
every AES key in every backup. Test that you can decrypt (step 4) before
you rely on it. `backup.crt` isn't secret. It lasts 20 years, but the
backups decrypt after it expires too. When you make a new pair, keep the
old key as long as you keep backups made for it.

**2. On each database server,** the certificate, the settings and the
timer, and a first backup now:

```bash
sudo install -D -m 0644 backup.crt /etc/radiator/backup.crt
sudo install -D -m 0644 /opt/radiator-yubikey/yubikey-backup.example.conf /etc/radiator/backup.conf
sudo systemctl enable --now yubikey-backup.timer
sudo systemctl start yubikey-backup.service
sudo /opt/radiator-yubikey/yubikey-backup.sh status
```

```text
the newest backup is 0 min old
newest: /var/backups/yubikey-db.cms.0, 2026-10-16 22:53:42 UTC, 20 KB
kept: 1 of 7, the oldest yubikey-db.cms.0 of 2026-10-16 22:53:42 UTC
last run: 2026-10-16 22:53:42 UTC, ok
encrypted to: CN = yubikey backups (SHA-256 06:9E:AE:5E:EA:1C:1E:C0:E8:55:CC:E1:85:A9:7A:14:CE:F8:99:19:DC:B3:A2:4C:87:8D:B9:02:2B:CF:6B:F5), until 2046-10-11
```

The timer starts it every day at about 03:00 (the server's time), or at
the next boot when the server was off then. `status` exits with 0 when
the newest backup is less than 26 hours old and the last run worked, and
1 otherwise, so monitoring can run it; `journalctl -u yubikey-backup` has
each run.

**3. Fetch them** to where you keep backups, as a member of the group
`adm` on the server (`sudo usermod -aG adm alice`):

```bash
scp db1.example.com:/var/backups/yubikey-db.cms.0 db1-$(date +%F).cms
```

**4. Check one now and then,** on your machine (with `postgresql-client`
and `openssl`). It changes nothing:

```bash
./yubikey-backup.sh check --key backup.key db1-2026-10-16.cms
```

```text
Enter pass phrase for backup.key:
db1-2026-10-16.cms: a whole backup of the YubiKey database, made 2026-10-16 22:53:41 UTC (PostgreSQL 18.6)
  it holds 5 YubiKeys (of 5 users), 4 service accounts, 4 groups
```

**5. To restore one,** decrypt it on your machine (the key stays there),
copy the dump to the primary, restore it there, and remove the dump from
both, since it holds every AES key in clear:

```bash
./yubikey-backup.sh decrypt --key backup.key db1-2026-10-16.cms yubikey-db.dump
scp yubikey-db.dump db1.example.com:
ssh -t db1.example.com sudo /opt/radiator-yubikey/yubikey-backup.sh restore yubikey-db.dump
ssh db1.example.com shred -u yubikey-db.dump && shred -u yubikey-db.dump
```

```text
Enter pass phrase for backup.key:
decrypted db1-2026-10-16.cms to yubikey-db.dump (20 KB, mode 0600)
The backup, made 2026-10-16 22:53:41 UTC: 5 YubiKeys (of 5 users), 4 service accounts, 4 groups.
The database yubikey now: 6 YubiKeys (of 6 users), 4 service accounts, 4 groups.
The restore puts the backup's tables back, and so undoes what changed since:
  YubiKeys added since the backup, which go: carol vvccccbbcdeh
  YubiKeys changed since the backup, which are put back as they were: bob vvccccbbcdeg (enabled again)
Counters that are ahead now stay, and so do the anycast checks' keys.
Restore it into yubikey? Type yes: yes
Restored the backup of 2026-10-16 22:53:41 UTC into yubikey: 5 YubiKeys, 4 service accounts, 4 groups.
Kept the counters of 1 YubiKey(s) that were ahead, and the keys of 3 anycast check(s).
```

In this example, alice logged in after the backup, bob's YubiKey was
disabled and carol's added. The restore replaces every table of the
database with the backup's, in one transaction (logins wait for it: a
tenth of a second in the test), and so undoes what changed since the
backup, which it lists first. Two things stay as they
are:

- **Counters that are ahead now**, so an OTP used since the backup stays
  used. A YubiKey deleted since the backup comes back with the backup's
  counters, and when the database is gone (a new one), every YubiKey has
  them: an OTP used after the backup could then be used once more, until
  the YubiKey's next login.
- **The anycast checks' keys** (`anycast-*`), which renew themselves: the
  checks go on logging in.

A YubiKey or account the list says is `enabled again` was disabled after
the backup: disable it again. It runs only on the primary (on a standby it
says so), and takes the backup decrypted already, or encrypted with
`--key`.

### After upgrading the scripts

From scripts installed by hand, as this guide said before version 1.6.0
(a clone in `/opt/yubikey-db`, and for three sites, copies in
`/usr/local/sbin` and units in `/etc/systemd/system`), install the package
as in [The radiator-yubikey package](#the-radiator-yubikey-package). A unit
in `/etc/systemd/system` hides the package's, which runs the script in
`/opt/radiator-yubikey`; `sudo /opt/radiator-yubikey/install.sh --check`
lists each one with the commands that replace it, for example:

```text
To do:
  - /etc/systemd/system/yubikey-anycast.service, installed by hand, hides the
    package's unit (which runs /opt/radiator-yubikey/yubikey-anycast.sh). To
    use the package's:
      sudo systemctl disable yubikey-anycast.service
      sudo rm /etc/systemd/system/yubikey-anycast.service
      sudo systemctl daemon-reload
      sudo systemctl enable yubikey-anycast.service
      sudo systemctl try-restart yubikey-anycast.service
```

Then remove the copies in `/usr/local/sbin` and the old clone.

After every upgrade, run `init` again (`sudo ./yubikey-db.sh init --owner radiator:radiator`, or
`./yubikey-db.sh -b pg init` as an admin). It adds what a newer version needs
to an existing database and changes nothing else. Version 1.2.1 adds the
trigger that stops the same OTP being accepted twice at the same moment (see
[Database layout](#database-layout)). Version 1.8.0 adds the `label`
column: `init` prints `Added the label column to the yubikeys table`, and
until you run it, the other commands stop with
`... was made by an older version of yubikey-db.sh; run 'yubikey-db.sh init' to bring it up to date`.
Radiator doesn't need the column, so it keeps working before and after.
Version 1.9.0 adds the `login_id` column to PostgreSQL's table, and changes
the trigger to use it: `init` prints
`Added the login_id column to the yubikeys table`. Then write Radiator's
clause again with `config` on each Radiator server (as in
[Install the configuration](#install-the-configuration); with partition
mode, as `yubikey-cluster.conf`), put Radiator's password back on the
`DBAuth` lines, and restart Radiator. Either can come first: until both are
done, Radiator works as before, and once both are, a login whose counters
were saved just as the primary stopped is answered (see
[Database layout](#database-layout)).
Version 1.10.0 adds the service-account and group tables (`init` prints
`Added the service-account and group tables`), and in PostgreSQL the
function with which the anycast check renews its key (`init` prints
`Added the function anycast_renew, with which the anycast check renews its key`);
until then, the check logs that it can't renew its key, and works as
before.
With two database servers or three sites, run `init` once, against the
primary; the standbys get the change by replication.

If your own tools add rows with `INSERT INTO yubikeys VALUES (...)`, without
naming the columns, as the old example commands did, they fail once the
table has the `label` column: name the columns, or use `add` or `import`.

### A database from the old example commands

The example statements that circulated before these scripts stored
`created` as the text `current_timestamp`, and `active` as the text `true` or
`false`. Radiator treats **both** texts as active, so a YubiKey set to
`false` was never disabled. Fix those rows:

```bash
sudo sqlite3 /etc/radiator/db/yubicred.db <<'SQL'
UPDATE yubikeys SET active = 1 WHERE active = 'true';
UPDATE yubikeys SET active = 0 WHERE active = 'false';
UPDATE yubikeys SET created = CURRENT_TIMESTAMP WHERE created = 'current_timestamp';
SQL
```

They also stored AES keys as hex, private IDs as modhex, and PINs in plain
text. Radiator reads hex keys and plain-text PINs, but with `CheckSecretId`
it rejects every login of a YubiKey whose private ID is stored as modhex.
`export` and then `import --from-export --replace` rewrite every row in the
format these scripts use (a modhex private ID becomes hex) and keep the
counters; so does a move to PostgreSQL, which also reports each change.

## Move from SQLite to PostgreSQL

`yubikey-db-migrate.sh` copies every user and YubiKey, **with their counters**
and labels, from the SQLite database into an empty PostgreSQL database, in one
transaction. It reads a consistent snapshot, so Radiator keeps running on
SQLite meanwhile, and commits only after checking every copied row against an
independent SHA-256 fingerprint of the snapshot. Rows from the old example
commands are normalized and each change is reported (for example, an
`active` of `false` becomes 0, and the report warns that those YubiKeys could
log in before).

It copies only the YubiKeys. [Service accounts and groups](#groups-and-tacacs)
aren't copied: it warns when the SQLite database has any, and you add them
again with `yubikey-db.sh -b pg`.

The account that runs it must be a member of `yubikey_admin` and able to read
the SQLite file, for example by joining the `radiator` group
(`sudo usermod -aG radiator "$USER"`, then log in again).

1. Create the PostgreSQL database (see
   [Create the database](#create-the-database)):
   `sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin "$USER"`. For a
   database made by an older version, run `./yubikey-db.sh -b pg init`
   instead, which brings it up to date.
2. Rehearse: `./yubikey-db-migrate.sh --dry-run /etc/radiator/db/yubicred.db`.
   It does everything, then rolls back.
3. Copy: `./yubikey-db-migrate.sh /etc/radiator/db/yubicred.db`.
4. Point Radiator at PostgreSQL:
   `./yubikey-db.sh -b pg config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null`,
   then `sudo systemctl restart radiator`.
5. Straight away, catch up with the logins made on SQLite since step 3:
   `./yubikey-db-migrate.sh --mode sync /etc/radiator/db/yubicred.db`.
   It moves counters forward where SQLite is ahead and adds YubiKeys added
   meanwhile. It never moves a counter backward, never deletes, and lists
   (without changing) rows that differ in username, PIN, `active`, key or
   label.

Without step 5, an OTP used on SQLite after the copy could be used once more
on PostgreSQL. Keep the SQLite file afterwards, unchanged, for a rollback.

**To roll back** to SQLite, first copy PostgreSQL's counters (and any users
added there) into SQLite, then switch:

```bash
./yubikey-db.sh -b pg export - | sudo ./yubikey-db.sh import --from-export --replace -
./yubikey-db.sh config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null
sudo systemctl restart radiator
```

## Two database servers

With one PostgreSQL server, logins stop when it does. A second server, kept
up to date by PostgreSQL's built-in streaming replication, can take over.
`tests/radiator/ha.sh` runs everything in this section with two database
servers and two Radiator servers (see [Testing](#testing)).

### How it works

- **One primary, one standby.** The primary accepts reads and writes. The
  standby receives each change from the primary as it happens (in the test,
  about 6 ms later) and accepts only reads.
- **Every Radiator server lists both servers** in one `DBSource`, with
  `target_session_attrs=read-write`. PostgreSQL's client library tries them in
  order and connects only to the one that accepts writes. So every Radiator
  server uses the primary, whichever server it lists first, and they all
  share one set of counters: an OTP used on one Radiator server is rejected on
  the others.
- **A failover is a promotion.** When the primary fails, you promote the
  standby with one command. It starts accepting writes, and every Radiator
  server connects to it within 10 seconds, with no change to its
  configuration. The failed server then comes back as the new standby.

Designs that look simpler but allow replays:

- **Two independent databases**, one per Radiator server, or two `DBSource`
  lines that point to separate databases: each keeps its own counters, so an
  OTP used on one is accepted on the other.
- **Two writable servers that replicate to each other** (PostgreSQL logical
  replication both ways): an OTP used on one server is accepted on the other
  until the change arrives, during normal operation, not only during
  failures. And when both servers update the same row, the change that
  arrives last wins, which can move a counter backward.

### The replay window

Replication is **asynchronous**: the primary saves a login's counters and
answers Radiator without waiting for the standby. If the primary dies in
that moment, the promoted standby doesn't have the newest counters, and those
OTPs can be used once more. Only OTPs used in the last fraction of a second
before the failure are affected, and only until the user's next login moves
the counter past them. In normal operation there is no window, because every
Radiator server writes to the same primary. The test shows the window by
stopping replication before a failover.

Synchronous replication (`synchronous_standby_names`) closes the window, but
with only two servers every login then stops whenever the standby is down.
This guide uses asynchronous replication.

### What users see during a failover

Measured by the test, with the settings `yubikey-db.sh config` writes:

| Situation | What Radiator does |
|---|---|
| The primary died or hangs, and the standby isn't promoted yet | It **rejects** every login with `Yubikey secret not found in database`. The first login after the failure takes 2 to 5 s (up to 2 s waiting for a query, plus up to 2 s for each server that doesn't answer), and so may the first one in each of Radiator's four farm processes. A process that has seen the failure rejects at once for the next 2 s (`FailureBackoffTime`) without trying, then tries again. |
| The primary was stopped cleanly, or is restarting, and the standby answers but isn't promoted yet | It **holds** each login and tries again every 0.5 s, for up to 5 s: a login held until the standby is promoted is accepted, only later. After 5 s it rejects, as above. Each of the four farm processes holds one login at a time. |
| The standby has been promoted | Logins work again within 2 to 3 s. |
| A Radiator server's connection to the old primary ended, and a writable server exists | It reconnects and answers the same login: nothing is rejected. That includes a login whose counters the old primary saved just before it stopped: Radiator saves them again on the new one. |
| An OTP used before the failure | Still rejected as a replay, unless it was used in the replay window. |

Radiator rejects logins while no server accepts writes, after holding them
for up to 5 s if every server answers; it doesn't stay silent. Without the
hooks that `config` writes, its log says `Request is ignored`, but the
YubiKey check returns a reject. Network devices that try their local accounts only when no RADIUS
server answers won't fall back to them, so keep your usual break-glass
procedure for a long outage.

### Set up the two servers

Below, the database servers are `db1.example.com` (`192.0.2.11`, the first
primary) and `db2.example.com` (`192.0.2.12`), and the Radiator servers are
`192.0.2.21` and `192.0.2.22`. The admin `opsadmin` works on `192.0.2.21`.

**On both database servers:**

1. Install PostgreSQL and a certificate for **that server's own name**, made
   as in [PostgreSQL on a separate server](#postgresql-on-a-separate-server)
   (step 1) and signed by the same CA: `CN=db1.example.com` and
   `subjectAltName=DNS:db1.example.com` on db1, and the same with `db2` on
   db2.

2. Make PostgreSQL listen with TLS and keep recent changes for the standby:

   ```bash
   sudo tee /etc/postgresql/18/main/conf.d/yubikey.conf >/dev/null <<'EOF'
   listen_addresses = '*'
   ssl = on
   ssl_cert_file = '/etc/postgresql/18/main/server.crt'
   ssl_key_file = '/etc/postgresql/18/main/server.key'
   wal_keep_size = '1GB'
   EOF
   ```

   `wal_keep_size` keeps the last 1 GB of changes on the primary, so a standby
   that was offline for a while can catch up. A login adds at most about 8 KB
   of changes, so that covers well over 100,000 logins.

3. Add the same lines on both servers, since either can be the primary, to
   `/etc/postgresql/18/main/pg_hba.conf`, **above** the first line that
   starts with `host`:

   ```text
   hostssl  yubikey      radiator    192.0.2.21/32  scram-sha-256
   hostssl  yubikey      radiator    192.0.2.22/32  scram-sha-256
   hostssl  yubikey      opsadmin    192.0.2.21/32  scram-sha-256
   hostssl  replication  replicator  192.0.2.11/32  scram-sha-256
   hostssl  replication  replicator  192.0.2.12/32  scram-sha-256
   ```

   Open TCP port 5432 to these addresses in any firewall.

4. Give the `postgres` user the CA certificate and the replication password,
   for when this server is the standby. Choose the replication password now;
   you set it on the primary in the next part:

   ```bash
   sudo install -d -m 0700 -o postgres -g postgres /var/lib/postgresql/.postgresql
   sudo install -m 0644 -o postgres -g postgres ca.crt /var/lib/postgresql/.postgresql/root.crt
   sudo touch /var/lib/postgresql/.pgpass
   sudo chown postgres:postgres /var/lib/postgresql/.pgpass
   sudo chmod 0600 /var/lib/postgresql/.pgpass
   echo '*:5432:replication:replicator:REPLICATION-PASSWORD' | sudo tee /var/lib/postgresql/.pgpass >/dev/null
   ```

5. Stop PostgreSQL from starting by itself when the server boots:

   ```bash
   echo manual | sudo tee /etc/postgresql/18/main/start.conf >/dev/null
   ```

   > [!WARNING]
   > A primary that restarts by itself after a failover is a second primary,
   > with old counters. A Radiator server that connects to it, for example
   > after a restart, accepts OTPs already used on the new primary. The test
   > shows this. With `manual`, PostgreSQL starts only when someone runs
   > `sudo systemctl start postgresql@18-main`: always on a standby, and on
   > the old primary only if no failover happened while it was down.

6. `sudo systemctl restart postgresql@18-main`.

**On db1, the first primary:** create the roles and the database as in
[PostgreSQL on a separate server](#postgresql-on-a-separate-server) (step 4),
then the replication role, with the password from step 4 above:

```bash
sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin opsadmin --set-password
sudo -u postgres psql -c '\password opsadmin'
sudo -u postgres psql -c 'CREATE ROLE replicator REPLICATION LOGIN'
sudo -u postgres psql -c '\password replicator'
```

**On db2, make it the standby.** This replaces db2's database files with a
copy of db1's; the old ones are moved aside:

```bash
sudo systemctl stop postgresql@18-main
sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.$(date +%Y%m%d-%H%M%S)
sudo -u postgres pg_basebackup -h db1.example.com -U replicator -D /var/lib/postgresql/18/main \
     -R -X stream -c fast -d 'sslmode=verify-full application_name=db2'
sudo systemctl start postgresql@18-main
```

`-R` makes it a standby that follows db1. Check on **db1**:

```bash
sudo -u postgres psql -c 'SELECT application_name, client_addr, state, sync_state, replay_lag FROM pg_stat_replication'
```

```text
 application_name | client_addr |   state   | sync_state |   replay_lag
------------------+-------------+-----------+------------+-----------------
 db2              | 192.0.2.12  | streaming | async      | 00:00:00.006296
(1 row)
```

Once it's streaming, delete the moved-aside folder on db2
(`sudo rm -rf /var/lib/postgresql/18/main.2*`).

### Configure Radiator for two servers

On each Radiator server, install the CA certificate as in
[PostgreSQL on a separate server](#postgresql-on-a-separate-server), list
both database servers in `PGHOST`, and write Radiator's configuration (see
[Install the configuration](#install-the-configuration)):

```bash
export PGHOST=db1.example.com,db2.example.com PGUSER=opsadmin PGSSLMODE=verify-full PGSSLROOTCERT=/etc/radiator/pg-ca.crt
./yubikey-db.sh -b pg config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null
sudoedit /etc/radiator/conf.d/yubikey.conf     # put Radiator's password on each DBAuth line
sudo systemctl restart radiator
```

`config` writes:

```apache
    DBSource     dbi:Pg:dbname=yubikey;host=db1.example.com,db2.example.com;port=5432;sslmode=verify-full;sslrootcert=/etc/radiator/pg-ca.crt;connect_timeout=2;target_session_attrs=read-write
    DBUsername   radiator
    DBAuth       RADIATOR-PASSWORD

    Timeout             2
    ConnectTimeout      5
    FailureBackoffTime  2
```

with two hooks, `ConnectionHook` and `NoConnectionsHook`, and two more
clauses, `YubiKeyConnect` and the group `YubiKeyLocal` (see below).

- `target_session_attrs=read-write` skips the standby, which only accepts
  reads. A server that doesn't answer is skipped too.
- `connect_timeout=2` gives up on a server that doesn't answer after 2 s.
  `ConnectTimeout` (Radiator's limit for the whole connection attempt) must
  be longer than that times the number of servers.
- `Timeout 2` gives up on a query after 2 s. Radiator's default is 60 s, and
  Radiator answers nothing else while it waits. The hooks below allow 6 s
  for 10 s after each new connection.
- `FailureBackoffTime 2`: when no server accepts writes, each of Radiator's
  processes rejects logins without trying for 2 s, then tries again, so
  logins work again within about 2 s of a promotion. Its default is 600 s,
  which would leave logins failing for 10 minutes after the standby is
  promoted. A longer time keeps rejecting after the promotion: with 10 s
  (and without the hooks below), a planned switchover on three sites
  rejected logins for about 10 s instead of 2 to 5 s. A shorter one tries
  more often while there is no primary, and each try waits up to 2 s for
  each server that doesn't answer, so more rejects take that long: in the
  lab, with the primary powered off, about 16% of rejects took about 3 s
  (5% with 10 s), and at a site cut off from the other two, about 14% took
  about 4 s (3% with 10 s).
- `ConnectionHook` and `NoConnectionsHook`, a few lines of Perl: when no
  server accepts writes but every listed server answers (the primary
  refuses connections or is shutting down, the others are standbys), as
  while you switch over, Radiator holds the login and tries again every
  0.5 s, for up to 5 s, instead of rejecting it. When a server doesn't
  answer at all (`timeout expired` or `No route to host` in the log), it
  doesn't hold: that server may be down for a while, and each held login
  keeps one of Radiator's processes busy. Radiator builds the query for a
  login before it runs it, and needs a connection to build it, so a
  process with no connection must connect first: the group `YubiKeyLocal`
  that the Handlers use runs `YubiKeyConnect` (it connects, holding the
  login the same way, then lets the login go on), then `YubiKeySQL`. And
  for 10 s after each new
  connection (Radiator reconnects only after a failure), a query may take
  6 s instead of 2: a primary just promoted saves a change only once a
  standby streams from it, 1.5 to 3 s in the lab. The hooks change
  Radiator's `SQLRetries`, `FailureBackoffTime` and `Timeout` while it
  runs, as Radiator 4.30's SQL module allows; the tests check them, so run
  them again with each new Radiator version.
- `YubiKeyConnect` also gives each login a random ID, which `UpdateQuery`
  passes to the database with the counters. When the primary stops while a
  login's counters wait for the standby to confirm them, as in a
  switchover, they are saved, but Radiator only sees its connection drop.
  It saves them again on the new primary, and the database accepts that
  second save as the same login's, instead of refusing it as a replay.
  Without the ID, such a login got no answer: on three sites, with four
  logins at a time at each site, 6 of 24 planned switchovers left 1 to 3
  logins unanswered (10 of 9,180 in all).

For the admins, put both servers in `PGHOST` in `~/.profile`, as above. One
`~/.pgpass` line with `*` as the host covers both:
`*:5432:yubikey:opsadmin:YOUR-PASSWORD`. With two servers in `PGHOST`, the
scripts connect to the one that accepts writes. If you also use `psql`
directly, add `PGTARGETSESSIONATTRS=read-write` to the `export` line.

### Check replication

On the primary, the query above should show the standby as `streaming`. If
it returns no row, the standby isn't receiving changes: look at the
standby's log (`/var/log/postgresql/postgresql-18-main.log`). On the standby:

```bash
sudo -u postgres psql -c 'SELECT status, sender_host, latest_end_time FROM pg_stat_wal_receiver'
```

shows `streaming` and the primary's name. Check this from your monitoring:
a standby that stopped receiving changes is noticed only at the next
failover, when it lacks every login since then.

### Fail over

When the primary is down:

1. **Make sure it stays down.** Power it off, or if you can still reach it,
   `sudo systemctl stop postgresql@18-main`. A primary that only hangs, or is
   cut off from you but not from a Radiator server, can come back and keep
   accepting logins from a Radiator server still connected to it.
2. Promote the standby, on the standby:

   ```bash
   sudo pg_ctlcluster 18 main promote
   sudo -u postgres psql -Atc 'SELECT pg_is_in_recovery()'     # f: it accepts writes now
   ```

3. Within 10 s every Radiator server uses it. Nothing changes on the Radiator
   servers or for the admins.

### Bring the old primary back as the standby

Don't start PostgreSQL on the old primary as it was. Make it a standby of the
new primary, with the commands from [Set up the two servers](#set-up-the-two-servers)
("On db2, make it the standby"), with the names swapped. For example, on db1
after db2 was promoted:

```bash
sudo systemctl stop postgresql@18-main
sudo mv /var/lib/postgresql/18/main /var/lib/postgresql/18/main.$(date +%Y%m%d-%H%M%S)
sudo -u postgres pg_basebackup -h db2.example.com -U replicator -D /var/lib/postgresql/18/main \
     -R -X stream -c fast -d 'sslmode=verify-full application_name=db1'
sudo systemctl start postgresql@18-main
```

Then check on db2 that db1 is `streaming`. The copy takes seconds for a
database of this size. Radiator servers keep using db2, even those that list
db1 first.

### Switch over for maintenance

To move the primary to the other server without losing any counter, for
example before patching the primary:

1. On the primary: `sudo systemctl stop postgresql@18-main`. A clean stop
   sends every change to the standby first.
2. On the standby: `sudo pg_ctlcluster 18 main promote`.
3. Make the old primary a standby, as above.

Run step 2 within a few seconds of step 1. For 5 s after step 1, Radiator
holds logins and accepts them once the standby is promoted; after that it
rejects them until step 2, and for up to `FailureBackoffTime` (2 s) after
it.

### Automatic failover

The failover in this section is done by a person, who confirms that the
primary is down before promoting the standby. A tool that does it
automatically must also stop the old primary from coming back as a primary,
which needs a third member to tell a dead server from a broken network
between two live ones. [Three sites](#three-sites) does this with Patroni
and etcd on three servers. Ubuntu 26.04 also packages pg_auto_failover (with
a separate monitor) and repmgr (with a witness), which aren't covered here.
Radiator's configuration is the same with any of them, since it follows
whichever server accepts writes.

## Three sites

With Radiator servers on three sites, each site's server can also hold a
copy of the database, and **Patroni** moves the primary to another site by
itself when the primary fails. The example below has three sites, West,
East1 and East2, with a 55 ms round trip between West and the East sites and
4 ms between East1 and East2.
`tests/radiator/geo.sh` runs everything in this section on three servers
with those delays (see [Testing](#testing)). To set up three sites with
partition mode, anycast, groups and TACACS+ from one input file instead of
step by step, see [Turn-key setup](#turn-key-setup).

### How three sites work

- **Each site's server runs the same three services:** etcd, PostgreSQL
  under Patroni, and Radiator.
- **etcd** is a small key-value store that the three servers keep
  identical: a change counts only when two of the three agree. Patroni keeps
  the name of the primary in it as a **lease** that the primary renews every
  10 s and that expires 30 s after the last renewal.
- **Patroni** starts and stops PostgreSQL. The server holding the lease is
  the primary; the other two stream every change from it. When the lease
  expires, the most up-to-date standby takes it and is promoted. A server
  that can't reach either of the others can't renew or take the lease, and
  its Patroni stops its PostgreSQL before the lease runs out. Nobody
  promotes anything by hand.
- **Quorum commit** (`synchronous_mode: quorum`): the primary confirms a
  change only after one of the two standbys has saved it. Every login that
  Radiator accepted is on two sites, so a failover loses no OTP: the
  [replay window](#the-replay-window) of two servers is closed. East2,
  4 ms away, usually confirms first; while East2 is down, West does. And a
  primary that the standbys no longer follow can't confirm any login.
- **West becomes the primary only as a last resort:** its
  `failover_priority` is 1, the East sites' is 2. When East2 and West are
  equally up to date, East2 is promoted.
- **Every Radiator server lists all three servers** (`PGHOST=east1,east2,west`)
  and uses whichever is the primary, as with
  [two servers](#configure-radiator-for-two-servers). Nothing changes on the
  Radiator servers when the primary moves.
- **A former primary rejoins by itself.** If it has changes that no standby
  confirmed (counter updates for logins it never answered), Patroni removes
  them with `pg_rewind` and makes it a standby.

The cost is distance: every login at West goes to the primary in the East.

### What users see on three sites

Measured by the test:

| Situation | Logins |
|---|---|
| Normal | East1 about 15 ms, East2 about 25 ms, West about 125 ms: two round trips to East1 more. In the test, the East times are mostly disk writes on the primary and on East2. The first login handled by each of Radiator's four processes also opens its connection to PostgreSQL: about 0.5 s at West. |
| West or East2 reboots | No login fails. While East2 is down, West confirms the primary's commits, so logins at the East sites take about 70 ms. |
| East1 (the primary) reboots | Nothing is rejected: while Patroni stops PostgreSQL and East2 takes over, Radiator holds the logins for a few seconds. No OTP is lost. |
| A planned switchover | Nothing is rejected or left unanswered: Radiator holds the logins until East2 is promoted, so the slowest take 3 to 6 s (measured with four logins at a time at each site). No OTP is lost. |
| East1 loses power | Rejected for about 35 s, until the lease expires and East2 is promoted. No OTP is lost. |
| Patroni crashes on the primary | Nothing: systemd starts it again, and it keeps the lease. |
| West is cut off from both East sites | No change at the East sites. At West, every login is rejected (`Yubikey secret not found in database`) after 4 to 6 s, until the network is back; after 10 s when the cut comes within 10 s of a new connection, whose query may take 6 s (see `ConnectionHook` above). West stays a standby and catches up within a minute afterwards. |
| East1's site is cut off from the others | At East1: no answer at first, then rejected. Elsewhere: rejected for about 45 s, then East2 is the primary. |
| The link between East1 and East2 fails | Logins at East1 and West work; East1's take about 85 ms, because West now confirms them. At East2 they are rejected until the link is back. |
| East2 and West down at once | East1 alone has no majority and stops being the primary: every login is rejected until one of them is back. |

As with two servers, Radiator rejects logins while it can't reach a primary;
network devices that try their local accounts only when no RADIUS server
answers won't fall back to them. (With [anycast](#anycast), a site that
can't log anyone in stops answering instead.) To log users in at a site
that can reach no primary, such as West when it is cut off, add
[partition mode](#partition-mode).

### Before you start

- **Names and addresses.** Below: `east1.example.com` (`192.0.2.31`),
  `east2.example.com` (`198.51.100.32`) and `west.example.com`
  (`203.0.113.33`). Each name must resolve on all three servers, including
  while the others are down: put them in `/etc/hosts` if your DNS lives on
  one site.
- **Firewall.** Between the three servers: TCP 2379 and 2380 (etcd), 5432
  (PostgreSQL) and 8008 (Patroni). From the admins' machines: 5432.
- **Maintenance one server at a time.** Two servers down at once leave no
  primary.

### Set up the three servers

**1. On all three servers**, install the packages, in addition to Radiator
and its modules from [Install on the servers](#install-on-the-servers):

```bash
sudo apt install postgresql postgresql-client libdbd-pg-perl \
                 etcd-server etcd-client patroni python3-etcd
```

Patroni needs `python3-etcd` for etcd, but its package doesn't install it.

**2. Make a CA and one certificate per server.** etcd, Patroni and PostgreSQL
use them for TLS in both directions, so each certificate has the server's
name and address, and is valid for servers and clients. On an admin machine:

```bash
openssl req -x509 -newkey rsa:3072 -nodes -days 3650 -subj "/CN=YubiKey DB cluster CA" \
        -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
        -keyout ca.key -out ca.crt
mkcert() {   # mkcert NAME ADDRESS
    openssl req -newkey rsa:3072 -nodes -subj "/CN=$1" \
            -addext "subjectAltName=DNS:$1,IP:$2" \
            -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
            -addext "extendedKeyUsage=serverAuth,clientAuth" -keyout "${1%%.*}.key" -out "${1%%.*}.csr"
    openssl x509 -req -in "${1%%.*}.csr" -CA ca.crt -CAkey ca.key -CAcreateserial -days 825 \
            -copy_extensions copy -out "${1%%.*}.crt"
}
mkcert east1.example.com 192.0.2.31
mkcert east2.example.com 198.51.100.32
mkcert west.example.com 203.0.113.33
```

Copy `ca.crt` and each server's own `.crt` and `.key` to it, and keep
`ca.key` offline. Any certificate this CA signs can change the cluster's
state in etcd, so use this CA only for these three servers. Patroni refuses
a CA certificate without the `keyUsage` line (Python 3.13 and later).

**3. etcd, on each server.** The package started a single-server etcd; stop
it, remove its data, and configure this server's member. On east1 (on the
others, change `ETCD_NAME`, the four addresses, and the file names):

```bash
sudo systemctl stop etcd
sudo rm -rf /var/lib/etcd/default
sudo install -d -m 0750 -o root -g etcd /etc/etcd/tls
sudo install -m 0644 ca.crt /etc/etcd/tls/ca.crt
sudo install -m 0644 east1.crt /etc/etcd/tls/server.crt
sudo install -m 0640 -o root -g etcd east1.key /etc/etcd/tls/server.key
sudo tee /etc/default/etcd >/dev/null <<'EOF'
ETCD_NAME=east1
ETCD_DATA_DIR=/var/lib/etcd/default
ETCD_LISTEN_PEER_URLS=https://192.0.2.31:2380
ETCD_LISTEN_CLIENT_URLS=https://192.0.2.31:2379
ETCD_INITIAL_ADVERTISE_PEER_URLS=https://192.0.2.31:2380
ETCD_ADVERTISE_CLIENT_URLS=https://192.0.2.31:2379
ETCD_INITIAL_CLUSTER=east1=https://192.0.2.31:2380,east2=https://198.51.100.32:2380,west=https://203.0.113.33:2380
ETCD_INITIAL_CLUSTER_STATE=new
ETCD_INITIAL_CLUSTER_TOKEN=yubikey-db
ETCD_CERT_FILE=/etc/etcd/tls/server.crt
ETCD_KEY_FILE=/etc/etcd/tls/server.key
ETCD_TRUSTED_CA_FILE=/etc/etcd/tls/ca.crt
ETCD_CLIENT_CERT_AUTH=true
ETCD_PEER_CERT_FILE=/etc/etcd/tls/server.crt
ETCD_PEER_KEY_FILE=/etc/etcd/tls/server.key
ETCD_PEER_TRUSTED_CA_FILE=/etc/etcd/tls/ca.crt
ETCD_PEER_CLIENT_CERT_AUTH=true
EOF
```

Then run `sudo systemctl start etcd` on all three at about the same time:
it waits until two members have started. Check from any of them:

```bash
sudo etcdctl --cacert /etc/etcd/tls/ca.crt --cert /etc/etcd/tls/server.crt --key /etc/etcd/tls/server.key \
     --endpoints https://192.0.2.31:2379 endpoint health --cluster
```

```text
https://192.0.2.31:2379 is healthy: successfully committed proposal: took = 34.243943ms
https://198.51.100.32:2379 is healthy: successfully committed proposal: took = 39.014402ms
https://203.0.113.33:2379 is healthy: successfully committed proposal: took = 294.70611ms
```

**4. Patroni, on each server.** Patroni creates and runs PostgreSQL from now
on, so remove the cluster the `postgresql` package created (it holds no data
yet), and give Patroni the certificate:

```bash
sudo pg_dropcluster --stop 18 main
sudo install -d -m 0750 -o root -g postgres /etc/patroni/tls
sudo install -m 0644 ca.crt /etc/patroni/tls/ca.crt
sudo install -m 0644 east1.crt /etc/patroni/tls/server.crt
sudo install -m 0640 -o root -g postgres east1.key /etc/patroni/tls/server.key
sudo install -m 0640 -o root -g postgres /dev/null /etc/patroni/18-main.yml
sudoedit /etc/patroni/18-main.yml
```

with this content on east1. On the others, change `name`, the address and
name under `restapi` and `connect_address`, and, on West only,
`failover_priority: 1`. Choose three passwords (the REST API's, the
replication role's and the rewind role's) and use the same ones on all
three servers:

```yaml
# The Debian helper scripts below take the version and cluster from the scope.
scope: 18-main
namespace: /postgresql-common/
name: east1

restapi:
  listen: 192.0.2.31:8008
  connect_address: east1.example.com:8008
  certfile: /etc/patroni/tls/server.crt
  keyfile: /etc/patroni/tls/server.key
  cafile: /etc/patroni/tls/ca.crt
  authentication:
    username: patroni
    password: REST-API-PASSWORD

ctl:
  cacert: /etc/patroni/tls/ca.crt
  certfile: /etc/patroni/tls/server.crt
  keyfile: /etc/patroni/tls/server.key

etcd3:
  hosts: 192.0.2.31:2379,198.51.100.32:2379,203.0.113.33:2379
  protocol: https
  cacert: /etc/patroni/tls/ca.crt
  cert: /etc/patroni/tls/server.crt
  key: /etc/patroni/tls/server.key

bootstrap:
  method: pg_createcluster
  pg_createcluster:
    command: /usr/share/patroni/pg_createcluster_patroni
  dcs:
    ttl: 30
    loop_wait: 10
    retry_timeout: 10
    synchronous_mode: quorum
    synchronous_node_count: 1
    postgresql:
      use_pg_rewind: true
      use_slots: true
      parameters:
        ssl: 'on'
        ssl_cert_file: /etc/patroni/tls/server.crt
        ssl_key_file: /etc/patroni/tls/server.key
        max_slot_wal_keep_size: 8GB

postgresql:
  create_replica_method:
    - pg_clonecluster
  pg_clonecluster:
    command: /usr/share/patroni/pg_clonecluster_patroni
  listen: '*:5432'
  connect_address: east1.example.com:5432
  # Patroni's own connections to this server use its socket: TLS with
  # verify-full fails for "localhost".
  use_unix_socket: true
  use_unix_socket_repl: true
  data_dir: /var/lib/postgresql/18/main
  bin_dir: /usr/lib/postgresql/18/bin
  config_dir: /etc/postgresql/18/main
  pgpass: /var/lib/postgresql/18-main.pgpass
  authentication:
    superuser:
      username: postgres
    replication:
      username: replicator
      password: REPLICATION-PASSWORD
      sslmode: verify-full
      sslrootcert: /etc/patroni/tls/ca.crt
    rewind:
      username: rewinder
      password: REWIND-PASSWORD
      sslmode: verify-full
      sslrootcert: /etc/patroni/tls/ca.crt
  parameters:
    unix_socket_directories: /var/run/postgresql
    logging_collector: 'on'
    log_directory: /var/log/postgresql
    log_filename: postgresql-18-main.log
  pg_hba:
    - local   all         all                     peer
    - local   replication replicator              scram-sha-256
    - hostssl replication replicator 192.0.2.31/32 scram-sha-256
    - hostssl postgres    rewinder   192.0.2.31/32 scram-sha-256
    - hostssl yubikey     radiator   192.0.2.31/32 scram-sha-256
    - hostssl yubikey     opsadmin   192.0.2.31/32 scram-sha-256
    - hostssl replication replicator 198.51.100.32/32 scram-sha-256
    - hostssl postgres    rewinder   198.51.100.32/32 scram-sha-256
    - hostssl yubikey     radiator   198.51.100.32/32 scram-sha-256
    - hostssl yubikey     opsadmin   198.51.100.32/32 scram-sha-256
    - hostssl replication replicator 203.0.113.33/32 scram-sha-256
    - hostssl postgres    rewinder   203.0.113.33/32 scram-sha-256
    - hostssl yubikey     radiator   203.0.113.33/32 scram-sha-256
    - hostssl yubikey     opsadmin   203.0.113.33/32 scram-sha-256

watchdog:
  mode: off

tags:
  failover_priority: 2
```

What the settings do:

- `ttl`, `loop_wait`, `retry_timeout` are Patroni's defaults: the lease
  lasts 30 s, the primary renews it every 10 s, and stops being the primary
  if it can't reach etcd for 10 s. Shorter values fail over sooner after a
  power loss but risk failovers on a slow network.
- `synchronous_mode: quorum` with `synchronous_node_count: 1`: one of the
  two standbys confirms every commit (see [How three sites work](#how-three-sites-work)).
- `use_slots` and `max_slot_wal_keep_size`: the primary keeps the changes
  a standby hasn't received yet, up to 8 GB, so a standby that was down for
  days catches up. Make sure the disk has room for it.
- `use_pg_rewind`: a former primary is rewound, not copied again.
- The `pg_hba` lines replace `pg_hba.conf` on every server: replication and
  rewind between the three servers, and `radiator` and `opsadmin` from the
  Radiator servers. Add a `hostssl yubikey opsadmin` line for each other
  machine the admins work from.
- `watchdog: mode: off`. Quorum commit already stops a server that lost the
  lease from confirming anything; a watchdog device would also restart a
  server whose Patroni hangs. It isn't covered here.

Debian's `patroni@` unit leaves Patroni stopped if it crashes, with
PostgreSQL still running unattended. Have systemd restart it, and enable it:

```bash
sudo mkdir -p /etc/systemd/system/patroni@18-main.service.d
printf '[Service]\nRestart=on-failure\n' | sudo tee /etc/systemd/system/patroni@18-main.service.d/restart.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl enable patroni@18-main
```

**5. Start Patroni**, first on east1, which creates the database:
`sudo systemctl start patroni@18-main`. When `patronictl` (below) shows
east1 as `Leader`, start it on east2 and west too. Each copies the database
from east1 and starts streaming:

```bash
sudo patronictl -c /etc/patroni/18-main.yml list
```

```text
+ Cluster: 18-main (7696030870670149068) -----------------+----+-------------+-----+------------+-----+----------------------+
| Member | Host              | Role           | State     | TL | Receive LSN | Lag | Replay LSN | Lag | Tags                 |
+--------+-------------------+----------------+-----------+----+-------------+-----+------------+-----+----------------------+
| east1  | east1.example.com | Leader         | running   |  1 |             |     |            |     | failover_priority: 2 |
| east2  | east2.example.com | Quorum Standby | streaming |  1 |   0/5000060 |   0 |  0/5000060 |   0 | failover_priority: 2 |
| west   | west.example.com  | Quorum Standby | streaming |  1 |   0/5000060 |   0 |  0/5000060 |   0 | failover_priority: 1 |
+--------+-------------------+----------------+-----------+----+-------------+-----+------------+-----+----------------------+
```

`Quorum Standby` means it can confirm the primary's commits. Patroni has
created the `replicator` and `rewinder` roles itself.

**6. The yubikey database, on the primary (east1).** Create the roles and
the database, set Radiator's password, and give the admin a password, as in
[PostgreSQL on a separate server](#postgresql-on-a-separate-server)
(step 4):

```bash
sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin opsadmin --set-password
sudo -u postgres psql -c '\password opsadmin'
```

The standbys receive all of it.

**7. Radiator, on each server.** Install the CA certificate, list all three
servers, and write Radiator's configuration, as in
[Configure Radiator for two servers](#configure-radiator-for-two-servers):

```bash
sudo install -m 0644 ca.crt /etc/radiator/pg-ca.crt
export PGHOST=east1.example.com,east2.example.com,west.example.com PGUSER=opsadmin \
       PGSSLMODE=verify-full PGSSLROOTCERT=/etc/radiator/pg-ca.crt
./yubikey-db.sh -b pg config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null
sudoedit /etc/radiator/conf.d/yubikey.conf     # put Radiator's password on each DBAuth line
sudo systemctl enable --now radiator
```

`config` writes `host=east1.example.com,east2.example.com,west.example.com`
with `target_session_attrs=read-write`, `connect_timeout=2` and
`ConnectTimeout 7`. List the servers in the same order everywhere, the
usual primary first: West's Radiator then connects straight to East1. Put
the same `PGHOST` in the admins' `~/.profile`, with a `~/.pgpass` line
`*:5432:yubikey:opsadmin:YOUR-PASSWORD`.

### Run the three sites

- **Check the cluster** with `sudo patronictl -c /etc/patroni/18-main.yml list`
  on any server: one `Leader`, two `Quorum Standby` members `streaming`, with
  a lag near 0. Monitor the same from outside with Patroni's REST API:
  `https://SERVER:8008/primary` answers 200 only on the primary,
  `/replica` only on a streaming standby, and `/health` on any server whose
  PostgreSQL runs. For example:
  `curl -s -o /dev/null -w '%{http_code}\n' --cacert ca.crt https://east1.example.com:8008/primary`.
- **Reboot one server at a time**, and check the cluster in between. A
  standby can simply be rebooted. Rebooting the primary hands the lease to
  East2 while Patroni shuts down.
- **Move the primary** with a planned switchover, which loses nothing and
  rejects logins for a few seconds:

  ```bash
  sudo patronictl -c /etc/patroni/18-main.yml switchover --candidate east2 --force
  ```

  After a failover, move it back to East1 the same way once East1 is a
  `Quorum Standby` again. Until then East1 is a standby, and if East2 fails
  too, West becomes the primary.
- **Don't start PostgreSQL yourself** (`pg_ctlcluster` or
  `postgresql@18-main`) on these servers. Patroni does, as a primary or a
  standby, and stops it when it must.
- **Copy a standby again** from the primary, if it can't catch up (it was
  down for longer than 8 GB of changes, about a million logins) or its disk
  was replaced:

  ```bash
  sudo patronictl -c /etc/patroni/18-main.yml reinit 18-main west --force --wait
  ```

### When a site is cut off

- **West cut off from both East sites:** East1 keeps the lease and East2
  confirms its commits; nothing changes at the East sites. West can't reach
  a primary: its logins are rejected. Its PostgreSQL stays a standby, so
  there is no second primary. When the network is back, it catches up by
  itself.
- **East1 (the primary) cut off from both others:** its Patroni can't renew
  the lease and stops PostgreSQL within about 10 s. A login on East1 in that
  moment gets no answer, because no standby confirms its commit. When the
  lease expires, East2 is promoted, and logins work again everywhere except
  at East1. When the network is back, East1 is rewound and rejoins as a
  standby; move the primary back to it.
- **The link between East1 and East2 fails, both still reaching West:**
  East1 keeps the lease (etcd still has a majority through West), and West
  confirms its commits, so logins at East1 take a WAN round trip longer.
  East2 can't reach the primary: its logins are rejected until the link is
  back.

With [partition mode](#partition-mode), a site that reaches neither of the
others logs users in from a copy of the keys instead.

## Partition mode

With [three sites](#three-sites), a site that can reach no other site can't
reach a primary either, so it rejects every login until the network is back.
**Partition mode** lets that site log users in from a copy of the keys on
its own server while it is cut off, and copies the counters back to the
primary when the network returns. It is optional: `yubikey-partition.sh`
runs it, on each of the three servers. `tests/radiator/geo.sh` tests it
after everything else (see [Testing](#testing)).

### How partition mode works

- **A copy of the keys on each server.** Every 5 minutes,
  `yubikey-partition.sh` updates a SQLite copy of the `yubikeys` table,
  `/var/lib/yubikey-partition/keys.db`, from the server's own PostgreSQL (a
  standby or the primary), through the local socket. New, changed, disabled
  and deleted YubiKeys follow; counters only move forward.
- **Cut off: Radiator uses the copy.** Every 5 s, the script checks whether
  the other two servers answer, on PostgreSQL's port or Patroni's. When
  neither has for 3 checks in a row, the server is cut off. The script
  updates the copy once more: a standby that is cut off still answers
  reads, with every change up to the cut. Then it points Radiator's
  `/etc/radiator/conf.d/yubikey.conf`, which is a link, at
  `yubikey-partition.conf` (Radiator's clause for the copy) instead of
  `yubikey-cluster.conf`, and restarts Radiator. Logins at that site work
  again, and their counters are saved in the copy.
- **If PostgreSQL doesn't answer at that moment, the last copy.** When the
  primary is cut off, Patroni stops its PostgreSQL, which then refuses
  connections for about a minute before it starts again as a standby. If
  partition mode begins during that minute, the copy is the one from the
  last 5-minute update, and it is updated as soon as PostgreSQL answers. (In
  the test, East1's PostgreSQL still answered when partition mode began.)
- **Back: the counters go to the primary.** When another server answers and
  the primary can be reached, twice in a row, the script copies to the
  primary the counters that moved forward in the copy (only forward, with
  Radiator's own database login), points the link back at the cluster,
  restarts Radiator, and copies once more, for logins in between.
- **Only when no other site answers.** A site that still reaches another
  site doesn't use its copy: East2 while only its link to East1 is down, or
  every site while Patroni replaces a primary. They reject, as before.

**The risks you accept with partition mode:**

- While a site is cut off, an OTP that a user typed at another site can be
  used once more at the cut-off site, which can't know about it. On a former
  primary whose PostgreSQL didn't answer when partition mode began, so can
  an OTP typed anywhere in the last 5 minutes before the cut, until it
  answers. And an OTP used at the cut-off site
  can be used once more at another site, until the network is back and its
  counters have reached the primary.
- A user disabled, a PIN changed or a YubiKey deleted elsewhere while a site
  is cut off still works at that site until the network is back.
- Each server keeps every AES key in a second place, the copy.

### What users see with partition mode

Measured by the test:

| Situation | Logins |
|---|---|
| West is cut off | At West, rejected until West enters partition mode, 13 to 15 s after the cut; logins from its copy work from 20 to 22 s (Radiator restarts in between), and an OTP used at another site just before the cut is a replay there too. At the East sites, nothing changes. 6 to 8 s after the network is back, West uses the primary again, and the OTPs used at West are replays everywhere. |
| East1 (the primary) is cut off | At East1, no answer at first, then rejected, then logins from its copy from 20 to 23 s. Elsewhere, as without partition mode: East2 takes over, and West and East2 stay in normal mode, as they reach each other. 7 to 10 s after the network is back, East1's counters are in the new primary. |
| East2 and West down at once | East1 logs users in from its copy from about 20 s, instead of rejecting until one of them is back. |
| The link between East1 and East2 fails | No change: East2 still reaches West, so it rejects until the link is back. |

With [anycast](#anycast), a cut-off site withdraws while its logins fail,
and advertises again once it logs users in from its copy.

### Set up partition mode

On each of the three servers, after
[Set up the three servers](#set-up-the-three-servers):

**1. The settings.** The package installed the script and its unit, and
`install.sh` the packages for the copy (`sqlite3` and
`libdbd-sqlite3-perl`):

```bash
cd /opt/radiator-yubikey
sudo install -m 0644 yubikey-partition.example.conf /etc/radiator/partition.conf
sudoedit /etc/radiator/partition.conf      # PEERS: the other two servers
```

On west, `PEERS="east1.example.com east2.example.com"`.

**2. Make the copy** and Radiator's two clauses:

```text
$ sudo ./yubikey-partition.sh setup
moved yubikey.conf to yubikey-cluster.conf (in /etc/radiator/conf.d)
the copy: /var/lib/yubikey-partition/keys.db, 4 YubiKeys
Radiator's clause: yubikey.conf -> yubikey-cluster.conf; in partition mode -> yubikey-partition.conf
```

`setup` moves the clause from step 7 of the three-site setup to
`yubikey-cluster.conf`, makes the copy (owned by `radiator`, which writes
the counters in partition mode), writes `yubikey-partition.conf`, and makes
`yubikey.conf` a link to `yubikey-cluster.conf`. From now on, change
Radiator's clause for PostgreSQL in `yubikey-cluster.conf`, never through
the link.

**3. Start it:**

```bash
sudo systemctl enable --now yubikey-partition
sudo ./yubikey-partition.sh status
```

```text
normal mode since 2026-10-13 14:08:21 UTC
peers answering: east1.example.com east2.example.com
copy: 4 YubiKeys, updated 14:08:31
Radiator uses: yubikey-cluster.conf
```

### Run partition mode

- **See the mode:** `sudo ./yubikey-partition.sh status` exits 0 in normal mode
  and 1 in partition mode, for monitoring. `journalctl -u yubikey-partition`
  logs each change:

  ```text
  started in normal mode: partition mode after 3 checks (15 s) in which none of east1.example.com east2.example.com answers; the copy is updated every 300 s
  copy: 4 YubiKeys, updated 15:33:34
  partition mode: none of east1.example.com east2.example.com answered in 3 checks; Radiator uses this server's copy of the keys (4 YubiKeys, updated just now)
  normal mode: Radiator uses the cluster again; counters moved forward in the primary for 2 YubiKeys
  ```

  If the server's PostgreSQL doesn't answer when partition mode begins, the
  `partition mode` line gives the time of the copy and ends with
  `cannot read this server's PostgreSQL: ...`, and
  `copy: updated from this server's PostgreSQL again` follows once it
  answers. While the copy can't be updated, `status` says why, in a line
  `copy not updated: ...`.

- **Maintenance stays one server at a time.** With two servers down, the
  third logs users in from its copy, with the risks above, until one of them
  is back.
- **Stopping the service leaves the mode as it is.** To return to the
  cluster by hand, `sudo ./yubikey-partition.sh leave`: it copies the counters
  to the primary first, and changes nothing if it can't.

## Anycast

With anycast, every Radiator server has the same IPv4 and IPv6 address on
its loopback interface, and **FRR** advertises it to the site's router with
BGP. The network devices are given that one address as their RADIUS server
(and TACACS+ server) and reach their own site's server. When a server can't
log anyone in, it stops advertising the address, and its site's devices
reach another site.

`yubikey-anycast.sh` decides: every 5 s it logs in to the local Radiator,
with a key of its own that works like a YubiKey's, and, with
[TACACS+](#groups-and-tacacs), over TACACS+ too. The example below adds
anycast to the three sites of the previous section. `tests/radiator/geo.sh` runs it with an FRR
router in front of the three servers (see [Testing](#testing)).

### How anycast works

- **One address for all servers:** `192.0.2.153` and `2001:db8:153::153`
  below, in none of your networks. Each server's FRR advertises them to its
  site's router, as `/32` and `/128`, while they are on the server's `lo`.
  Each router prefers its own server, so devices use their own site.
- **The check puts them on `lo` and takes them off.** Every 5 s it logs in
  to Radiator through 127.0.0.1 as `anycast-` and the server's name (for
  example `anycast-west`), with a PIN and an OTP made from its own key, and
  checks that Radiator listens on the anycast addresses. A login succeeds
  only if Radiator works, reaches the primary, and the primary saved the
  OTP's counter. After 2 good checks in a row the addresses go on `lo`, and
  FRR advertises them. After 3 failed checks they come off, and FRR
  withdraws them.
- **With TACACS+, a check is two logins.** With `TACACS_KEY` in its
  settings, each check also logs in over TACACS+, at the same time, as the
  service account `svc.anycast-` and the server's name, with a password of
  its own; asks for the session's authorization, as a device does; and
  checks that Radiator listens on TCP port 49 on the anycast addresses. The
  check fails if either login fails, so a server whose TACACS+ is broken is
  withdrawn like one whose RADIUS is. The TACACS+ login goes through the
  same password and group checks as anyone's, and uses no OTPs.
- **The check renews its key every year.** Like a YubiKey's, its OTPs have
  counters that only go up, so a key runs out: after about 485 days at one
  check every 5 s. Every 365 days, after a good check, the running check
  gives its key a new private ID and AES key, in the database and in its
  key file, and its counters start again. It writes with Radiator's own
  login, through a function in the database that can change only the keys
  of `anycast-*` users. Never in partition mode.
- **Nothing is advertised unless the check says so.** The addresses aren't
  in the server's network configuration, and FRR's configuration never
  changes: FRR advertises what is on `lo`, even after it restarts. A server
  that reboots, or whose check stops or crashes, advertises nothing until
  its check has passed twice again. Stopping the check
  (`systemctl stop yubikey-anycast`) withdraws the addresses at once, which
  is how to take a server out for maintenance.
- **BFD** tells the router that a server is gone within a second, instead
  of after BGP's hold time (minutes, by default).
- **Radiator listens on the anycast addresses even while they aren't on
  `lo`.** Two kernel settings (`ip_nonlocal_bind`) allow that, so a Radiator
  that starts while its server is withdrawn answers as soon as the addresses
  are back. Its `BindAddress` lists them, so the reply to a request sent to
  an anycast address comes from that address: network devices drop a reply
  from any other address.
- **The check's users work nowhere else.** Radiator accepts `anycast-*`
  users (and `svc.anycast-*` service accounts) only from 127.0.0.1, and
  doesn't write their logins to the authentication log.

The check withdraws a server whenever its logins fail, whatever the reason.
While no server can log anyone in, for example while Patroni replaces a
primary that lost power, every server withdraws after 3 checks, and devices
get **no answer** instead of a reject until a server's check passes again.
A network device that falls back to its local accounts when no RADIUS
server answers will do so during that time. With
[partition mode](#partition-mode), a site that reaches no other site logs
users in from its copy, so its check passes and it keeps advertising.

### What devices see with anycast

Measured by the test, with the router preferring West, then East1, then
East2:

| Situation | Logins at the anycast address |
|---|---|
| Normal | Answered by West, from the anycast address, over IPv4 and IPv6. |
| West's Radiator stops | No answer for about 13 s (3 failed checks), then East1 answers. West is back 8 or 9 s after Radiator starts again. |
| West's check is stopped (maintenance) | East1 answers at once. |
| West reboots | East1 answers while West is down: West's check stops first, and its BGP session closes. West is back once its check passes twice. |
| West loses power | The router drops West within a second (BFD); East1 answers. |
| West can't reach the primary (cut off from the East sites) | Rejected for about 15 s, then East1 answers, if the devices can still reach it. West is back two checks after it can log in again. |
| The primary (East1) loses power | Rejected at first; West and East2 withdraw 10 to 17 s after the power loss (3 failed checks), and there is no answer until they advertise again, 35 to 45 s after it. |
| East2 and West down at once | East1 withdraws too: no answer until one of them is back. |

### Before you start

- **The anycast addresses:** one IPv4 and one IPv6 address for RADIUS, the
  same on every server, in none of your networks: `192.0.2.153` and
  `2001:db8:153::153` below.
- **Each server's own IPv6 address**, for its BGP session over IPv6:
  `2001:db8:31::31` (east1), `2001:db8:32::32` (east2) and `2001:db8:33::33`
  (west) below. Their routers are `192.0.2.1` and `2001:db8:31::1`,
  `198.51.100.1` and `2001:db8:32::1`, and `203.0.113.1` and
  `2001:db8:33::1`.
- **The cluster stays on IPv4.** The three servers' names in `/etc/hosts`
  have IPv4 addresses only; etcd, Patroni and PostgreSQL keep using those.
  If a name also resolves to an IPv6 address, PostgreSQL may refuse the
  connection (`no pg_hba.conf entry for host "2001:..."`).
- **AS numbers:** the servers use one private AS, `65053` below, the same on
  all three; the routers use yours, `64500` below.
- **Firewall:** between each server and its router, TCP 179 (BGP) and UDP
  3784 (BFD). From the devices to the anycast addresses, UDP 1812, and TCP
  49 for TACACS+.
- **The devices** get the anycast addresses as their RADIUS server (and
  TACACS+ server). Each server still needs a `<Client>` for each device,
  with the same secret (and TACACS+ key) on every server.

### Set up anycast on each server

**1. Install FRR** and the settings (the package installed the script and
its unit):

```bash
sudo apt install frr
cd /opt/radiator-yubikey
sudo install -m 0600 yubikey-anycast.example.conf /etc/radiator/anycast.conf
```

**2. Let Radiator listen on the anycast addresses** while they aren't on
`lo`:

```bash
printf 'net.ipv4.ip_nonlocal_bind = 1\nnet.ipv6.ip_nonlocal_bind = 1\n' \
    | sudo tee /etc/sysctl.d/60-radiator-anycast.conf
sudo sysctl -p /etc/sysctl.d/60-radiator-anycast.conf
```

**3. Radiator.** `radiator.example.conf` has the two `<Handler>` clauses
for the check's users, before the one for everyone else; copy them into an
older `radiator.conf`. (`radiator-groups.example.conf` has them, and a
third, for the check's TACACS+ login.) Then set `BindAddress` (commented
out in the example) to 127.0.0.1, the server's own addresses and the
anycast addresses. On west:

```apache
BindAddress     127.0.0.1, 203.0.113.33, ipv6:2001:db8:33::33, 192.0.2.153, ipv6:2001:db8:153::153
```

```bash
sudo systemctl restart radiator
ss -Hlun 'sport = :1812'
```

`ss` lists one socket for each of the five addresses (and so does
`ss -Hltn 'sport = :49'`, with TACACS+). Without `BindAddress`, Radiator
listens on all addresses, and its replies to requests sent to an anycast
address come from the server's own address.

**4. FRR.** Turn on its BGP and BFD daemons:

```bash
sudo sed -i 's/^bgpd=no/bgpd=yes/; s/^bfdd=no/bfdd=yes/' /etc/frr/daemons
sudoedit /etc/frr/frr.conf
```

`/etc/frr/frr.conf`, on west (on the others, change the name, the
`router-id` and the router's addresses):

```text
frr defaults traditional
hostname west
log syslog informational
!
ip prefix-list RADIUS-ANYCAST seq 10 permit 192.0.2.153/32
ipv6 prefix-list RADIUS-ANYCAST seq 10 permit 2001:db8:153::153/128
!
route-map RADIUS-ANYCAST permit 10
 match ip address prefix-list RADIUS-ANYCAST
exit
route-map RADIUS-ANYCAST permit 20
 match ipv6 address prefix-list RADIUS-ANYCAST
exit
route-map NOTHING deny 10
exit
!
router bgp 65053
 bgp router-id 203.0.113.33
 no bgp default ipv4-unicast
 neighbor 203.0.113.1 remote-as 64500
 neighbor 203.0.113.1 bfd
 neighbor 2001:db8:33::1 remote-as 64500
 neighbor 2001:db8:33::1 bfd
 !
 address-family ipv4 unicast
  network 192.0.2.153/32
  neighbor 203.0.113.1 activate
  neighbor 203.0.113.1 route-map NOTHING in
  neighbor 203.0.113.1 route-map RADIUS-ANYCAST out
 exit-address-family
 !
 address-family ipv6 unicast
  network 2001:db8:153::153/128
  neighbor 2001:db8:33::1 activate
  neighbor 2001:db8:33::1 route-map NOTHING in
  neighbor 2001:db8:33::1 route-map RADIUS-ANYCAST out
 exit-address-family
exit
```

- FRR advertises a `network` only while the server has a route for it: here,
  while the address is on `lo`. (That is FRR's `bgp network import-check`,
  on by default.)
- The server sends its router the two anycast routes and nothing else
  (`RADIUS-ANYCAST out`), and takes none from it (`NOTHING in`). FRR ignores
  an eBGP neighbor without these route maps.
- One session per address family (`no bgp default ipv4-unicast`): IPv4 routes
  over the IPv4 session, IPv6 routes over the IPv6 one.

```bash
sudo chown frr:frr /etc/frr/frr.conf
sudo chmod 0640 /etc/frr/frr.conf
sudo systemctl restart frr
sudo vtysh -c 'show bgp summary' -c 'show bfd peers brief'
```

Both sessions should be up (a time under `Up/Down`) and both BFD peers
`up`, with 0 routes sent (`PfxSnt`) until the check runs.

**5. The check.** Put the anycast addresses and the secret of
`<Client 127.0.0.1>` in `/etc/radiator/anycast.conf`
(`sudoedit /etc/radiator/anycast.conf`), and with TACACS+, its
`TACACSPLUSKey` as `TACACS_KEY`. Then give the check its key, in the
database, as the admin (with the `PGHOST` and `~/.pgpass` from
[Set up the three servers](#set-up-the-three-servers), step 7):

```bash
sudo ./yubikey-anycast.sh enroll | ./yubikey-db.sh -b pg import --replace -
```

`enroll` makes a key, a PIN and the user `anycast-west`, keeps them in
`/var/lib/yubikey-anycast/key` (mode `0600`), and prints them as one CSV
line for `import`, through the pipe, never on a command line.

With TACACS+, also give the check its service account, in a group that may
log in to the server itself (device group `localhost`). The group and its
access are made once, on the first server:

```bash
sudo ./yubikey-anycast.sh enroll-tacacs | ./yubikey-db.sh -b pg service add "svc.anycast-$(hostname -s)" -l 'anycast check'
./yubikey-db.sh -b pg group add anycast-check -l 'yubikey-anycast.sh over TACACS+'   # first server only
./yubikey-db.sh -b pg access set anycast-check localhost 1                           # first server only
./yubikey-db.sh -b pg member add anycast-check "svc.anycast-$(hostname -s)"
```

`enroll-tacacs` makes a password of 32 letters and digits for
`svc.anycast-west`, keeps it in `/var/lib/yubikey-anycast/tacacs` (mode
`0600`), and prints it for `service add`, through the pipe. Then try the
check, and start it:

```bash
sudo ./yubikey-anycast.sh check
sudo systemctl enable --now yubikey-anycast
```

`check` prints `ACCEPT in 148 ms` (at West); with TACACS+, it adds
`; TACACS+ PASS` and that login's time. About 10 s after the start, the
addresses are on `lo`, and the router has the routes:

```text
$ sudo ./yubikey-anycast.sh status
advertised since 2026-10-13 12:26:43 UTC
last check: ACCEPT in 127 ms, 1 s ago
on lo: 192.0.2.153 2001:db8:153::153
OTPs left: 8386814 (485 days at one check every 5 s)
key: next renewal on 2027-10-13
```

On the server, `sudo vtysh -c 'show bgp summary'` now shows 1 route sent
(`PfxSnt`) on each session.

### The routers

Each site's router needs:

- **A BGP session with its server over IPv4 and over IPv6**, with BFD, in
  the server's AS (`65053`).
- **A filter:** accept only `192.0.2.153/32` and `2001:db8:153::153/128` from
  the server, at most one route per session, and send it nothing (it would
  ignore anything anyway).
- **The anycast routes passed on to the other sites' routers**, like your
  other routes, so that each router has all three servers' routes and
  prefers its own: a route from a router's own eBGP neighbor already wins
  over the same route learned from another router; or set a local
  preference.
- **No default route for the anycast addresses:** when no server advertises
  them, a static route with a high distance can reject them, rather than
  send them to the internet.

In the test, one FRR router stands in for West's and peers with all three
servers. For west, its configuration is:

```text
ip prefix-list RADIUS-ANYCAST seq 10 permit 192.0.2.153/32
ipv6 prefix-list RADIUS-ANYCAST seq 10 permit 2001:db8:153::153/128
!
ip route 192.0.2.153/32 reject 250
ipv6 route 2001:db8:153::153/128 reject 250
!
route-map FROM-WEST permit 10
 match ip address prefix-list RADIUS-ANYCAST
 set local-preference 300
exit
route-map FROM-WEST permit 20
 match ipv6 address prefix-list RADIUS-ANYCAST
 set local-preference 300
exit
route-map NOTHING deny 10
exit
!
router bgp 64500
 no bgp default ipv4-unicast
 neighbor 203.0.113.33 remote-as 65053
 neighbor 203.0.113.33 bfd
 neighbor 2001:db8:33::33 remote-as 65053
 neighbor 2001:db8:33::33 bfd
 address-family ipv4 unicast
  neighbor 203.0.113.33 activate
  neighbor 203.0.113.33 route-map FROM-WEST in
  neighbor 203.0.113.33 route-map NOTHING out
  neighbor 203.0.113.33 maximum-prefix 1
 exit-address-family
 address-family ipv6 unicast
  neighbor 2001:db8:33::33 activate
  neighbor 2001:db8:33::33 route-map FROM-WEST in
  neighbor 2001:db8:33::33 route-map NOTHING out
  neighbor 2001:db8:33::33 maximum-prefix 1
 exit-address-family
exit
```

East1's and East2's servers have the same lines, with local preferences 200
and 100.

### Run anycast

- **See what a server advertises:** `sudo ./yubikey-anycast.sh status` (it
  exits 0 only while the addresses are on `lo`, for monitoring), and
  `journalctl -u yubikey-anycast`, which logs each change and each new kind
  of check result:

  ```text
  started: anycast-west logs in every 5 s; 192.0.2.153 2001:db8:153::153 on lo after 2 good checks, off after 3 failed; 8388095 OTPs left (485 days); key made 2026-10-13, next renewal on 2027-10-13
  check: ACCEPT in 580 ms
  advertising 192.0.2.153 2001:db8:153::153: 2 good checks
  check: NO REPLY: Connection refused
  withdrawing 192.0.2.153 2001:db8:153::153: 3 failed checks
  ```

  (The first login of each of Radiator's processes at West takes about
  0.5 s, while it connects to the primary. Radiator was stopped before the
  fourth line.) With TACACS+, each `check:` line also has the result of
  the TACACS+ login, for example
  `check: ACCEPT in 31 ms; TACACS+ FAIL in 12 ms: No such user` (see
  [Troubleshooting](#troubleshooting)).

  On a router, `show bgp ipv4 unicast 192.0.2.153/32` lists the servers
  that advertise it.
- **Before maintenance on a server, stop its check:**
  `sudo systemctl stop yubikey-anycast`. Its site's devices move to another
  site at once. Start it when you are done; the server is back after two
  good checks. A reboot does this by itself: the check stops before
  Radiator and FRR do.
- **The check renews its key by itself,** 365 days after the key was made
  (`RENEW_DAYS` in `/etc/radiator/anycast.conf`), or sooner if only 30 days
  of OTPs are left, after a good check. The log says so:

  ```text
  renewing the key (made 2026-10-16)
  renewed the key of anycast-west (public ID vvcbdefhijkl): a new private ID and AES key; next renewal on 2028-10-15
  ```

  `status` ends with the date of the next renewal
  (`key: next renewal on 2027-10-16`). To renew the key now, stop the
  check, run `sudo ./yubikey-anycast.sh renew`, and start it.
- **Renewing needs PostgreSQL:** the function `anycast_renew`, which
  `yubikey-db.sh -b pg init` adds; `psql`; and Radiator's login, with its
  password on the `DBAuth` line, as in the three-site setup. The check
  reads it from `yubikey-cluster.conf`, or from `yubikey.conf` without
  partition mode. If a renewal fails, the check tries again an hour later,
  or 6 checks later if its logins with the old key fail (the database may
  have the new one). Without these (SQLite, or a database from before
  1.10.0 that `init` hasn't updated), replace the key by hand: stop the
  check, run the `enroll` and `check` lines of step 5 again, and start it.
  `enroll` keeps the public ID, so `import --replace` replaces the old key.
- **With partition mode,** a renewal waits while the server is in partition
  mode, and the copy gets the new key at its next sync (within `SYNC`
  seconds, 300 by default). A server that enters partition mode before then
  withdraws, as its check's logins fail, until it leaves partition mode.
  After a renewal by hand, `sudo ./yubikey-partition.sh sync` closes that
  gap.
- **Taking a server away for good:**
  `sudo systemctl disable --now yubikey-anycast`, then remove its check's
  user: `./yubikey-db.sh -b pg delete anycast-west`, and with TACACS+, its
  service account: `./yubikey-db.sh -b pg service delete svc.anycast-west`.

## Groups and TACACS+

With `radiator-groups.example.conf` instead of `radiator.example.conf`,
Radiator also takes logins over **TACACS+** (TCP port 49), and checks every
login, RADIUS or TACACS+, against **groups** in the same database: which
accounts may log in to which devices, at which TACACS+ privilege level, with
which commands, and with which RADIUS reply attributes. It also takes
**service accounts**: accounts that log in with a password instead of a
YubiKey, for scripts and tools, named `svc.NAME`.

### How groups work

- A **device group** is the `Identifier` of the devices' `<Client>`
  clauses in Radiator, for example `core` for the core switches. Several
  devices or subnets can share one. A `<Client DEFAULT>` clause takes every
  device that isn't listed, in a device group of its own.
- A **group** holds accounts: YubiKey users and service accounts.
- **Access** lets a group log in to the devices of a device group (or to
  every device, `*`), at a TACACS+ privilege level from 0 to 15, with RADIUS
  reply attributes for RADIUS logins, and, if you want, TACACS+ command
  rules.
- At each login, after the YubiKey or password check, Radiator looks for
  the most privileged of the account's groups that may use the device's
  group (a named device group before `*`). If there is none, the login is
  rejected. An account counts only while it can log in: it has an active
  YubiKey, or it is an active service account.
- Over TACACS+, the device then asks Radiator to authorize the session
  (exec), and, if it is set up to, each command. Radiator answers with the
  group's privilege level and command rules. Each of these requests asks
  the database again, so a change applies within 2 seconds, even to
  sessions already open: taking a group's access away, or disabling an
  account, stops its commands.
- Command rules are tried in order, and the first that matches decides. A
  command no rule matches is denied. A group with no rules on a device
  group may run every command there.
- `enable` on a device is a second login, which takes a new OTP. With the
  privilege level from the group, users don't need it.
- The groups are in the database: a change applies on every server at
  once, with no Radiator restart. The devices are in Radiator's
  configuration: adding one takes `sudo systemctl restart radiator`, which
  also closes the TACACS+ connections that are open (devices open new ones).

Radiator 4.30's TACACS+ has no TLS. Its packets are protected only by the
device's key (RFC 8907's MD5-based obfuscation): give each device a long
random key, and keep TACACS+ on your management network.

### What devices see

| Situation | TACACS+ | RADIUS |
|---|---|---|
| Login, and a group may use the device | Pass; the session gets the group's privilege level | `Access-Accept`, with the group's reply attributes |
| Login, and none of the account's groups may use the device | Fail | `Access-Reject` |
| A command the rules deny | Authorization fails | |
| A command, after the account was disabled or its group's access taken away | Authorization fails (within 2 s) | |
| No database server answers | Refused at first (by each of Radiator's processes, for up to a second), then no answer (an error), so the device may try another server. Nothing is allowed. | As for any login (see [What users see during a failover](#what-users-see-during-a-failover)) |

### Set up groups and TACACS+

These steps were run as written by `tests/radiator/groups.sh` (see
[The automated test](#the-automated-test)), for SQLite and PostgreSQL. Add
`-b pg` to every `yubikey-db.sh` command for PostgreSQL. From the package's
folder:

```bash
cd /opt/radiator-yubikey
```

1. Add the service-account and group tables to the database. `init` is
   safe to re-run, and says `Added the service-account and group tables`:

   ```bash
   sudo ./yubikey-db.sh init         # SQLite
   ./yubikey-db.sh -b pg init        # PostgreSQL, as a member of yubikey_admin
   ```

2. Install the dictionary and the configuration, in place of
   `radiator.example.conf`, and make the folder for the devices:

   ```bash
   sudo install -m 0644 dictionary.yubikey /etc/radiator/dictionary.yubikey
   sudo install -m 0640 -o root -g radiator radiator-groups.example.conf /etc/radiator/radiator.conf
   sudo install -d -m 0750 -o root -g radiator /etc/radiator/clients.d
   sudoedit /etc/radiator/radiator.conf
   ```

   In the editor, change the `Secret` and `TACACSPLUSKey` of
   `<Client 127.0.0.1>`, and set `BindAddress` as for
   [anycast](#set-up-anycast-on-each-server) if you use it (step 5 there
   lets the anycast check log in over TACACS+ too).

3. Write the clauses again, as in
   [Install the configuration](#install-the-configuration): `config` now
   also writes `ServiceAccounts` and `GroupAccess`.

   ```bash
   ./yubikey-db.sh config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null          # SQLite
   ./yubikey-db.sh -b pg config | sudo tee /etc/radiator/conf.d/yubikey.conf >/dev/null    # PostgreSQL
   ```

4. Put the devices in files in `/etc/radiator/clients.d` (mode `0640`,
   owner `root:radiator`, since they hold the secrets and keys), one
   `<Client>` per device or subnet, for example
   `sudoedit /etc/radiator/clients.d/core.conf`:

   ```apache
   <Client 192.0.2.10>
       Identifier     core
       Secret         a-long-random-secret-for-radius
       TACACSPLUSKey  another-long-random-key-for-tacacs
   </Client>
   <Client 198.51.100.0/24>
       Identifier     access
       Secret         a-long-random-secret-for-radius
       TACACSPLUSKey  another-long-random-key-for-tacacs
   </Client>
   ```

   `openssl rand -base64 32` makes a good secret or key.

5. Make the groups, put accounts in them, and give them access:

   ```bash
   sudo ./yubikey-db.sh group add netadmins -l 'network team'
   sudo ./yubikey-db.sh member add netadmins alice carol
   sudo ./yubikey-db.sh access set netadmins core 15 -r 'cisco-avpair="shell:priv-lvl=15"'
   sudo ./yubikey-db.sh access set netadmins access 15
   sudo ./yubikey-db.sh group add helpdesk
   sudo ./yubikey-db.sh member add helpdesk bob
   sudo ./yubikey-db.sh access set helpdesk access 1
   sudo ./yubikey-db.sh rule add helpdesk access 'permit service=shell cmd=show'
   ```

   Helpdesk may now only run `show` commands on the access switches, and
   log in nowhere else. Check what an account gets on a device group:

   ```bash
   sudo ./yubikey-db.sh access check bob access
   ```

   ```text
   bob may log in to devices in access, as a member of helpdesk (access to access), at privilege level 1
   TACACS+ rules, the first that matches decides:
     permit service=shell cmd[*=] {priv-lvl=1}
     permit service=shell cmd=show
   RADIUS reply: (none)
   ```

   The first rule is the privilege level, which every access gets.

6. Check the configuration and restart Radiator, as in
   [Check and start](#check-and-start), and allow TCP port 49 from the
   devices in the firewall, as well as RADIUS.

7. Test from the server: the RADIUS login with `radpwtst` as in
   [Check the whole path](#check-the-whole-path-radpwtst), and a TACACS+
   login with Radiator's own client, with the key of `<Client 127.0.0.1>`
   (the server itself is device group `localhost`, so give a test group
   access to it first):

   ```bash
   sudo ./yubikey-db.sh access set netadmins localhost 1
   read -rsp 'PIN:OTP: ' pw; echo
   perl /opt/radiator/radiator/goodies/tacacsplustest -s 127.0.0.1 -key local-test-key \
       -user alice -password "$pw" -noacct -notrace; echo $?
   sudo ./yubikey-db.sh access delete netadmins localhost
   ```

   Type alice's PIN, a colon, and touch her YubiKey. `tacacsplustest`
   prints `OK` for the login and `OK` for its authorization (of
   `telnet host1`, which a group with no rules may run), and exits with 0.

### Service accounts

A service account logs in with a password, at least 12 characters, stored
as a `{crypt}` SHA-512 hash like the PINs. Its name is `svc.` followed by
letters, digits and `. _ @ + -`, which is how Radiator tells it from a
YubiKey user. Like any account, it may log in only where its groups allow.

```bash
sudo ./yubikey-db.sh service add svc.backup -l 'nightly config backup'   # asks for the password twice
sudo ./yubikey-db.sh service add svc.monitor --generate                  # makes one, and shows it once
sudo ./yubikey-db.sh group add backup
sudo ./yubikey-db.sh member add backup svc.backup
sudo ./yubikey-db.sh access set backup core 15
sudo ./yubikey-db.sh rule add backup core 'permit service=shell cmd=show cmd-arg=running-config'
sudo ./yubikey-db.sh rule add backup core 'permit service=shell cmd=copy'
```

| Task | Command |
|---|---|
| List service accounts (no passwords) | `sudo ./yubikey-db.sh service list` |
| Change a password | `sudo ./yubikey-db.sh service password svc.backup` (or `--generate`) |
| Suspend one, or turn it back on | `sudo ./yubikey-db.sh service disable svc.backup`, `service enable svc.backup` |
| Remove one (and take it out of its groups) | `sudo ./yubikey-db.sh service delete svc.backup` |

Without a terminal, `service add` and `service password` read the password
from the first line of standard input.

### Command rules

A rule is `permit`, `permitreplace` or `deny`, then one pattern for each
argument of the TACACS+ request, in order, as Radiator's `AuthorizeGroup`
takes them. Each pattern is a Perl regular expression that must match the
whole argument. A device asks about `show running-config` as
`service=shell cmd=show cmd-arg=running-config cmd-arg=<cr>`; a rule with
fewer patterns than the request has arguments ignores the rest.

| Rule | Allows or denies |
|---|---|
| `permit service=shell cmd=show` | Every `show` command |
| `permit service=shell cmd=show cmd-arg=running-config` | Only `show running-config` |
| `deny service=shell cmd=reload` | `reload` |
| `permit service=shell` | Every command |
| `deny .*` | Everything |

```bash
sudo ./yubikey-db.sh rule add netadmins core 'deny service=shell cmd=reload'
sudo ./yubikey-db.sh rule add netadmins core 'permit service=shell'
sudo ./yubikey-db.sh rule list netadmins core
sudo ./yubikey-db.sh rule delete netadmins core 10
sudo ./yubikey-db.sh rule add netadmins core 'permit service=shell cmd=show' --seq 5   # before the first
```

Rules are numbered 10, 20, 30 and so on; `--seq` puts one in between. Once
a group has rules on a device group, a command none of them matches is
denied, so the netadmins example above ends with `permit service=shell`. A
rule may not contain a double quote, or an octal escape such as `\101`.

| Task | Command |
|---|---|
| List groups, members and access | `sudo ./yubikey-db.sh group list` |
| List the access of every group | `sudo ./yubikey-db.sh access list` |
| Change a privilege level | `sudo ./yubikey-db.sh access set helpdesk access 5` |
| Change or remove RADIUS reply attributes | `access set helpdesk access 5 -r 'Service-Type=Login-User'`, or `-r ''` |
| Take a group's access away (and its rules) | `sudo ./yubikey-db.sh access delete helpdesk access` |
| Take an account out of a group | `sudo ./yubikey-db.sh member delete helpdesk bob` |
| Delete a group (with its members, access and rules) | `sudo ./yubikey-db.sh group delete helpdesk` |

With [partition mode](#partition-mode), the copy on each server also holds
the service accounts and groups; the next sync (`SYNC` seconds) brings a
change to it. A copy made by an older version gets their tables at the next
sync, if `yubikey-db.sh` is next to `yubikey-partition.sh` (as in the
package).

## Turn-key setup

`yubikey-turnkey` does all of [Three sites](#three-sites),
[Partition mode](#partition-mode), [Anycast](#anycast) and
[Groups and TACACS+](#groups-and-tacacs) for you, from one input file:
you describe the three servers, their routers, the anycast addresses, the
devices and the groups in `site.toml`, and it makes a folder for each
server, with a `setup.sh` that installs and configures everything on it,
and the sheets to hand to whoever runs the routers and the devices.
`tests/radiator/turnkey.sh` runs it on three fresh servers (see
[Testing](#testing)).

### How the turn-key setup works

- **One input file, with no secrets in it.** `site.toml` lists the three
  servers (the usual primary first, and the one far from the others as the
  last resort), each one's router or two, the anycast addresses, the admins
  and their subnets, the devices with their device groups, and the groups
  to start with. `site.example.toml`, in the package, is an example with
  everything it assumes in its comments.
- **Every secret is made once.** The passwords, the RADIUS secrets and
  TACACS+ keys, the anycast checks' keys, and the cluster's CA and
  certificates are made the first time, in `secrets.toml` next to
  `site.toml` (mode `0600`), and taken from there on every later run: the
  same input always gives the same output, until `--rotate` makes new ones
  (see [Rotate passwords and keys](#rotate-passwords-and-keys)). Keep
  `secrets.toml`, and back it up.
- **A folder per server, made by the tool.** In `out/` next to
  `site.toml`: `east1/`, `east2/` and `west/`, each with `setup.sh`, the
  server's settings (`server.env`, `secrets.env`), every file it installs
  (`files/`, listed with their modes in `files.list`), and the database's
  contents (`db/`), which the primary's `setup.sh` applies. Next to them, `runbook.md`
  (the order to do things in), `routers.md`, `devices.md`, `admin/`
  (the files for the admins' machines), and with `[backup]`,
  `secrets.toml.cms`.
- **`setup.sh` does the steps of the sections above,** in order: the
  packages (PostgreSQL, Patroni, etcd and FRR from Ubuntu; Radiator and
  radiator-yubikey from the packages next to it, and later ones over them:
  see [Upgrade a turn-key setup](#upgrade-a-turn-key-setup)), `/etc/hosts` and the
  kernel settings, the cluster's TLS files, etcd, Patroni, the database,
  Radiator (`radiator-groups.example.conf` with the server's addresses and
  devices), partition mode, FRR and the anycast check, the backups, and
  the firewall. It ends with a report: the cluster, the anycast check, the
  BGP sessions.
- **The three run at the same time.** etcd starts only when two servers
  run it; the first server's Patroni creates the cluster, which the other
  two copy; the first server makes the database, and the others wait for
  it. Each says what it waits for.
- **It is safe to run again.** Each step changes only what differs from
  the folder, and restarts a service only when its files changed. If
  `setup.sh` stops, fix the cause and run it again: it goes on where it
  stopped. It never removes an etcd cluster or a PostgreSQL cluster with
  databases that it didn't make; `--reset` starts a server over.
- **A lost server comes back from its folder.** On a new server with the
  same name and addresses, or after `--reset` on it alone, `setup.sh`
  joins the other two: it adds the server's etcd member again, Patroni
  copies the database, and the anycast check takes its key and counter
  from the database (see
  [Rebuild a turn-key server](#rebuild-a-turn-key-server)). With two lost,
  `--alone` makes the third the cluster alone first (see
  [Two servers lost](#two-servers-lost)).
- **One command says whether a server works:** `setup.sh --status` checks
  its services, the cluster, the anycast check, partition mode, BGP, the
  backups, the firewall, the certificates, the disk and the clock, without
  changing anything, and sums it up in its first line, for you and for
  monitoring.
- **Backups, encrypted for a key that isn't on the servers** (with
  `[backup]` in `site.toml`, as in the example): each server makes the
  [automatic backups](#automatic-backups), and `yubikey-turnkey` writes
  `secrets.toml` encrypted for the same certificate, which each server
  keeps too (see [Turn-key backups](#turn-key-backups)).
- **The database's contents, each once.** The primary's `setup.sh` (the
  first server's, unless it failed over) loads the three anycast checks'
  keys and TACACS+ service accounts, the group `anycast-check`, and the
  groups in `site.toml`, each only if it isn't there yet, and removes the
  anycast checks of servers no longer in `site.toml`. After that, change
  the groups with `yubikey-db.sh`: a later run doesn't undo it, and a key
  the check has renewed stays.
- **The devices are in the folders.** Radiator's `<Client>` clauses come
  from `site.toml`. To add a device, add it there, run `yubikey-turnkey`
  again, copy the folders and run `setup.sh` on each server, which restarts
  Radiator (and so closes the TACACS+ connections that are open).
- **The firewall** (when on, as by default): `setup.sh` turns ufw off and
  loads iptables rules for the whole server, kept by `iptables-persistent`
  (with the nft backend). Only these come in: from the devices to the
  anycast addresses, RADIUS and TACACS+ (from anyone, with the catch-all
  client); between the three servers, etcd, PostgreSQL and Patroni; from
  the admin subnets, SSH, PostgreSQL and Patroni's REST API; from the
  server's routers, BGP and BFD; ICMP, and replies to the server's own
  connections. It refuses to load them while an SSH connection to the
  server comes from outside the admin subnets.

### Set up three sites with yubikey-turnkey

**1. On an admin's machine**, with the radiator-yubikey package (or the
release's tarball), Python 3.11 or later and `openssl`, make `site.toml`
from the example, and the backups' key pair next to it (step 1 of
[Automatic backups](#automatic-backups) says how to keep the key):

```bash
cp /opt/radiator-yubikey/site.example.toml site.toml
editor site.toml
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -aes-256-cbc -out backup.key
openssl req -new -x509 -key backup.key -days 7300 -subj "/CN=yubikey backups" -out backup.crt
```

`site.toml` names only the certificate (`[backup] certificate =
"backup.crt"`); `yubikey-turnkey` refuses a file that holds a private key.

**2. Make the folders,** with the packages copied into each (`-p`): put
Radiator's packages from Radiator Software, and the release's
`radiator-yubikey_VERSION_all.deb` and `install.sh` (the same version as
`yubikey-turnkey`), in one folder first:

```bash
/opt/radiator-yubikey/yubikey-turnkey -p ~/packages site.toml
```

```text
made secrets.toml, with every password, key and certificate
out/admin/: 3 written
wrote out/devices.md
out/east1/: 38 written
out/east2/: 35 written
wrote out/routers.md
wrote out/runbook.md
wrote out/secrets.toml.cms
out/west/: 35 written
```

Run it again with no change and it says `out: up to date`. It checks the
whole input first, and lists every error it finds, for example
`site.toml: device[3].address: '10.2.0.1/24' is not an address or a subnet (with the host bits 0)`;
it writes nothing until there are none.

Read `out/runbook.md`: it has the steps below with your servers' names.

**3. Copy each server's folder to it,** readable by root only, and check
the server. `--check` changes nothing:

```bash
scp -r out/east1/ root@east1.example.com:/root/turnkey    # and east2, west
sudo /root/turnkey/setup.sh --check                        # on each server
```

```text
== preflight
  ok    Ubuntu 26.04
  ok    host name east1
  ok    address 192.0.2.31/
  ok    address 2001:db8:31::31/
  ok    clock synchronized
  ok    Radiator's packages are here
  ok    radiator-yubikey 1.12.1's package and install.sh are here
  ok    ports
  ok    198.51.100.32 reachable
  ok    203.0.113.33 reachable
  ok    SSH connections from the admin subnets only

Nothing to fix.
```

Each `FAIL` line says what to fix; a `WARN` line (no NTP, little disk)
doesn't stop it.

**4. Run `setup.sh` on all three,** at about the same time (within 30
minutes):

```bash
sudo /root/turnkey/setup.sh
```

On east1, which finishes first (the others are still copying the
database):

```text
== packages
  ..    installing postgresql postgresql-client libdbd-pg-perl etcd-server etcd-client patroni python3-etcd frr sqlite3 curl openssl ca-certificates iptables iptables-persistent radiator_4.30-1_all.deb radiator-radius-utilxs_2.4-4.resolute_amd64.deb (apt-get's output is in /var/log/yubikey-turnkey.log)
  ..    installing radiator-yubikey 1.12.1 with its install.sh (its output is in /var/log/yubikey-turnkey.log)
  ok    packages: Radiator 4.30-1, radiator-yubikey 1.12.1, PostgreSQL 18+290ubuntu1, Patroni 4.1.0-2, etcd 3.5.16-10, FRR 10.5.1-1ubuntu4.1

== system
  ..    updated /etc/hosts
  ..    installed /etc/sysctl.d/60-radiator-anycast.conf
  ..    installed /etc/yubikey-turnkey/server.env
  ..    installed /etc/yubikey-turnkey/secrets.env
  ok    /etc/hosts, kernel settings

== etcd
  ..    installed /etc/etcd/tls/ca.crt /etc/etcd/tls/server.crt /etc/etcd/tls/server.key /etc/default/etcd
  ok    etcd: 3 members healthy

== patroni
  ..    removed the postgresql package's empty cluster 18/main
  ..    installed /etc/patroni/tls/ca.crt /etc/patroni/tls/server.crt /etc/patroni/tls/server.key /etc/patroni/18-main.yml /etc/systemd/system/patroni@18-main.service.d/restart.conf
  ok    Patroni: east1=Leader/running west=Replica/stopped

== database
  ok    database yubikey; roles radiator and opsadmin, with their passwords
  ok    the anycast checks of east1 east2 west: keys, service accounts, group anycast-check
  ok    group netadmins
  ok    group helpdesk

== radiator
  ..    installed /etc/radiator/dictionary.yubikey
  ..    installed /etc/radiator/pg-ca.crt /etc/radiator/radiator.conf /etc/radiator/clients.d/core.conf /etc/radiator/clients.d/access.conf /etc/radiator/clients.d/catch-all.conf
  ..    installed /etc/radiator/conf.d/yubikey.conf
  ok    Radiator listens on UDP 1812 and TCP 49

== partition
  ..    installed /etc/radiator/partition.conf
  ..    moved yubikey.conf to yubikey-cluster.conf (in /etc/radiator/conf.d)
  ..    the copy: /var/lib/yubikey-partition/keys.db, 3 YubiKeys
  ..    Radiator's clause: yubikey.conf -> yubikey-cluster.conf; in partition mode -> yubikey-partition.conf
  ok    partition mode: yubikey-partition runs; Radiator uses yubikey-cluster.conf

== anycast
  ..    installed /etc/radiator/anycast.conf /var/lib/yubikey-anycast/key /var/lib/yubikey-anycast/counter /var/lib/yubikey-anycast/tacacs /etc/frr/frr.conf
  ok    the anycast check: ACCEPT in 46 ms; TACACS+ PASS in 50 ms

== backup
  ..    installed /etc/radiator/backup.crt /etc/radiator/backup.conf /var/backups/yubikey-turnkey-secrets.toml.cms
  ok    backups: every day at about 03:00, in /var/backups; the newest backup is 0 min old

== firewall
  ..    installed /etc/iptables/rules.v4 /etc/iptables/rules.v6
  ok    firewall: 13 IPv4 and 10 IPv6 rules

== report
  Patroni:  east1=Leader/running east2=Replica/creating replica west=Replica/creating replica
  anycast:  advertised since 2026-10-16 13:46:05 UTC; last check: ACCEPT in 32 ms; TACACS+ PASS in 18 ms, 0 s ago
  BGP:      192.0.2.1 Established, 2001:db8:31::1 Established

east1 is set up.
```

The other two wait for etcd, for east1's Patroni and for its database,
and say so (`waiting for east1 to create the database (its setup.sh) (40 s)`),
then do the same steps. In the test, the three took three and a half
minutes, most of it `apt-get`. Run it again, on any server, and every step says
`ok` without installing or restarting anything.

It logs to `/var/log/yubikey-turnkey.log`, keeps its state in
`/var/lib/yubikey-turnkey`, and keeps a copy of `server.env` and
`secrets.env` in `/etc/yubikey-turnkey`.

**5. The routers and the devices,** as `out/routers.md` and
`out/devices.md` say. Each server advertises the anycast addresses once
its BGP sessions are up and its check passes.

**6. The admins' machines:** `out/admin/` has the cluster's CA
certificate, PostgreSQL settings for `yubikey-db.sh` (`pg.env`), and a
`~/.pgpass` line for each admin's login. Then add the YubiKeys and put
the accounts in the groups, as in
[Groups and TACACS+](#set-up-groups-and-tacacs):

```bash
cp out/admin/ca.crt ~/.yubikey-ca.crt
install -m 0600 out/admin/pgpass ~/.pgpass      # your own line only, if there are several
. out/admin/pg.env                              # PGHOST and the rest, and DB_BACKEND=pg
cd /opt/radiator-yubikey
./yubikey-db.sh import users.csv
./yubikey-db.sh member add netadmins alice
```

### Check a turn-key server

`setup.sh --status` checks the server it runs on, and changes nothing:

```bash
sudo /root/turnkey/setup.sh --status
```

```text
east1: OK

  ok    running: etcd patroni@18-main radiator frr yubikey-anycast yubikey-partition
  ok    etcd: 3 members healthy
  ok    Patroni: east1 Leader; east2 Quorum Standby, lag 0 MB; west Quorum Standby, lag 0 MB
  ok    Radiator: listening on UDP 1812 and 1813 and TCP 49, at 127.0.0.1 and the anycast addresses
  ok    anycast: advertised since 2026-10-16 13:46:05 UTC; last check: ACCEPT in 32 ms; TACACS+ PASS in 18 ms, 2 s ago
  ok    the check's key: next renewal on 2027-10-16
  ok    normal mode since 2026-10-16 13:46:12 UTC; the copy for partition mode: 4 YubiKeys, updated 13:51:12
  ok    BGP: 192.0.2.1 Established, 2001:db8:31::1 Established
  ok    backups: the newest backup is 5 h old, 7 of 7 kept
  ok    firewall: 13 IPv4 and 10 IPv6 rules
  ok    certificates: this server's until 2029-01-19, the CA's until 2036-10-14
  ok    disk: 41 GiB free in /var/lib
  ok    clock synchronized
  ok    setup.sh: finished 2026-10-16 13:46:20 UTC, radiator-yubikey 1.12.1
```

Each line is `ok`, `WARN` (it works, but something needs you) or `FAIL`
(this server doesn't do its part):

| Line | `WARN` | `FAIL` |
|---|---|---|
| `running` | | A service isn't running |
| `etcd` (each member, at its own address) | Two of the three are healthy | No quorum |
| `Patroni` | Another server isn't streaming, or is more than 16 MB behind; a server needs a restart; the primary isn't the usual one (after a failover) | No primary; this server isn't streaming from it |
| `Radiator` | | Not listening on RADIUS (UDP 1812, 1813) or TACACS+ (TCP 49), at 127.0.0.1 or an anycast address |
| `anycast` | Its last check was more than a minute ago | The addresses aren't advertised |
| `the check's key` | A renewal is due and hasn't worked | Less than a week of OTPs left |
| partition mode | In partition mode; the copy isn't updated | The service isn't running |
| `BGP` | A session is down | None is up |
| `backups` | The newest is more than 26 hours old; the last one failed; the daily timer is off | |
| `firewall` | The rules aren't loaded | |
| `certificates` | This server's or the CA's expires within 60 days | This server's has expired |
| `disk`, `clock` | Less than 10 GiB free in `/var/lib`; the clock isn't synchronized | Less than 1 GiB free |
| `setup.sh` | It hasn't finished on this server; the folder changed since it last finished (copied, but not run); the folder is for another version of radiator-yubikey | |

The first line is `east1: OK`, or `east1: WARNING - ` or
`east1: CRITICAL - ` followed by what's wrong, and it exits with 0, 1 or 2:
what monitoring tools such as Nagios, Icinga or Zabbix expect from a check
(3, `UNKNOWN`, when it can't check, such as not as root). Run it on each
server: each sees the cluster from where it is. It takes about a second.

Without the folder, the package's copy does the same, with the copy of
`server.env` that `setup.sh` keeps in `/etc/yubikey-turnkey`. For a
monitoring agent that runs as its own user (here `nagios`), allow it that
one command:

```bash
echo 'nagios ALL=(root) NOPASSWD: /opt/radiator-yubikey/yubikey-turnkey-setup.sh --status' \
    | sudo tee /etc/sudoers.d/yubikey-status >/dev/null
sudo chmod 0440 /etc/sudoers.d/yubikey-status
sudo -u nagios sudo -n /opt/radiator-yubikey/yubikey-turnkey-setup.sh --status
```

### Turn-key backups

With `[backup]` in `site.toml`, `setup.sh` installs the certificate and
`/etc/radiator/backup.conf`, starts the daily timer and makes the first
backup on each server: the [automatic backups](#automatic-backups), with
`keep` of them (7 by default: `/var/backups/yubikey-db.cms.0` to `.6`).

```toml
[backup]
certificate = "backup.crt"  # next to site.toml; its private key is kept elsewhere
keep = 7
```

- **Fetch them and check one now and then** as in steps 3 and 4 of
  [Automatic backups](#automatic-backups). `setup.sh --status` warns when
  the newest is more than 26 hours old, the last one failed, or the timer
  is off.
- **Restore one** on the primary (east1, unless it failed over), as in
  step 5. The anycast checks' keys stay, so all three servers go on
  advertising.
- **After losing the whole cluster:** set up servers with the same names
  and addresses, copy the folders and run `setup.sh` on all three, as on
  new servers, which makes the database anew with the anycast checks and
  the groups of `site.toml`, and then restore the last backup on east1.
  `tests/radiator/turnkey.sh` does this after `--reset` on all three.
- **`secrets.toml`, encrypted:** `yubikey-turnkey` writes
  `out/secrets.toml.cms`, `secrets.toml` encrypted for the same
  certificate, and each server keeps a copy as
  `/var/backups/yubikey-turnkey-secrets.toml.cms`. It is made again only
  when `secrets.toml` or the certificate changes, so the output stays the
  same. If you lose `secrets.toml`, fetch a copy and decrypt it:

  ```bash
  ./yubikey-backup.sh decrypt --key backup.key yubikey-turnkey-secrets.toml.cms secrets.toml
  ```

- **A new key pair:** replace `backup.crt`, run `yubikey-turnkey`, copy
  the folders and run `setup.sh` on each server, which makes a backup for
  the new certificate at once. Keep the old key while you keep backups
  made for it.
- **Without `[backup]`**, the servers make no backups (`yubikey-turnkey`
  says so), and `setup.sh` turns the timer off where it was on; the
  backups already made stay.

### Rebuild a turn-key server

When a server is lost (its disk, say, or Ubuntu installed anew), set it
up again with the same name and addresses while the other two run. In the
meantime the other two sites log users in, and the routers send the lost
site's devices to them; if it was the primary, Patroni has made East2 the
primary within about 30 s.

**1. A server with the same name and addresses:** Ubuntu 26.04 LTS, with
its host name and its IPv4 and IPv6 addresses as in `site.toml` (step 1
of the runbook). For a server whose disk is fine but whose etcd or
PostgreSQL is broken, start it over in place instead:
`sudo /root/turnkey/setup.sh --reset NAME`.

**2. Its folder,** as `yubikey-turnkey` last made it, with the packages:
copy it as in step 2 of the runbook.

**3. Run `setup.sh` on it alone:**

```bash
sudo /root/turnkey/setup.sh
```

It sets up the server as a new one, except:

- **etcd:** the cluster still has the server's member from before, without
  its data. `setup.sh` removes that member and adds it again, through
  the other two (both must run etcd), as a learner, which counts for no
  quorum until it has caught up; the server's etcd joins the cluster that
  runs, and `setup.sh` then makes it a voting member.
- **Patroni** copies the database from the primary, as a standby: the first
  server's too, which then isn't the primary (step 5).
- **The database** is left as it is: the first server loads nothing from
  `db/` again.
- **The anycast check** takes its key and its counter from the database,
  so it goes on with a key it renewed since (the folder has the one from
  before), and its first OTP is above the last one the database saw.

On West, whose check had renewed its key (in the lab):

```text
== etcd
  ..    installed /etc/etcd/tls/ca.crt /etc/etcd/tls/server.crt /etc/etcd/tls/server.key /etc/default/etcd
  ..    etcd: removed this server's member from before (512d880f0d6ebf0e), to add it again
  ..    etcd: added this server's member (9ac3382badfb3812), as a learner until it has caught up
  ..    etcd: promoted this server's member, which has caught up
  ok    etcd: joined the cluster; 3 members healthy

== patroni
  ..    removed the postgresql package's empty cluster 18/main
  ..    installed /etc/patroni/tls/ca.crt /etc/patroni/tls/server.crt /etc/patroni/tls/server.key /etc/patroni/18-main.yml /etc/systemd/system/patroni@18-main.service.d/restart.conf
  ..    waiting for this server to copy the database and stream from the primary (11 s)
  ok    Patroni: east1=Leader/running east2=Quorum_Standby/streaming west=Replica/streaming

== database
  ok    the database has this server's anycast check
...
== anycast
  ..    installed /var/lib/yubikey-anycast/key
  ..    the anycast check's key from the database: renewed on 2026-10-17
  ..    installed /var/lib/yubikey-anycast/counter
  ..    installed /etc/radiator/anycast.conf /var/lib/yubikey-anycast/tacacs /etc/frr/frr.conf
  ok    the anycast check: ACCEPT in 73 ms; TACACS+ PASS in 54 ms
```

On the first server, Patroni says
`the cluster exists, with east2 as its primary: this server copies it, as a standby`,
and the database
`this server's PostgreSQL isn't the primary now: the database was made before; left as it is`.

**4. Check all three** with `setup.sh --status`: each says `OK`.

**5. The first server:** it is a standby now, and its `--status` warns
that the primary is East2. Move the primary back when it suits you
(logins are held for a few seconds):

```bash
sudo patronictl -c /etc/patroni/18-main.yml switchover --candidate east1 --force
```

- **Two servers down at once:** etcd on the third has no quorum, so no
  member can be removed or added, and `setup.sh` stops at etcd, before
  starting it:

  ```text
  setup.sh: error: etcd: the cluster has this server's member from before, and fewer than two servers run etcd, which adding it again needs. Start etcd on the other two (see "Rebuild a turn-key server" in the guide)
  ```

  If the other server is only down, or its etcd stopped, start it and run
  `setup.sh` again. If it is lost too, see
  [Two servers lost](#two-servers-lost).
- **All three servers' etcd down** (a power cut at every site, say):
  nothing answers, so `setup.sh` starts etcd as in a new cluster, and waits;
  once the other two run etcd again, it joins them. A server rebuilt
  before, whose member was added again then, starts as the member it was
  at first, which the others removed: they refuse it, and `setup.sh` says
  `etcd: the others refused this server's etcd, started as in a new cluster: they have its member under another ID`,
  and adds its member again.
- **New names or addresses:** see
  [Replace a turn-key server](#replace-a-turn-key-server).
- `tests/radiator/turnkey.sh` rebuilds West, whose check had renewed its
  key, and East1, lost while it was the primary, on new servers; starts
  East2 over in place with `--reset`; and starts West over while East2's
  etcd is stopped, and while all three's is.

### Two servers lost

When two servers are lost at once, for good, the third goes on alone:
partition mode logs users in there from its copy (see
[What users see with partition mode](#what-users-see-with-partition-mode)),
and the routers send every device to it. (For the first seconds no login
is answered: the third's anycast check fails until partition mode is on,
and the third may withdraw its addresses until the check has passed
again.) But its etcd has no quorum, so
its PostgreSQL isn't the primary, and nothing in the database can change.
`setup.sh --alone` makes it the cluster alone; then you set up the other
two again.

**Only when both are lost for good.** If they still run, cut off from the
third, they are still a cluster, with a primary, and `--alone` makes a
second one: there are then logins and changes on both sides, which nothing
brings together again. `--alone` refuses while either answers on etcd's,
PostgreSQL's or Patroni's ports, but from the third a cut network looks
the same as a lost server: make sure at the sites.

**1. On the third server** (here West):

```bash
sudo /root/turnkey/setup.sh --alone
```

It asks, and then:

- **etcd** starts once with `--force-new-cluster`, which keeps its data and
  makes it the only member, and then as before.
- **Patroni** doesn't make its PostgreSQL the primary by itself: in quorum
  mode, without the other standby, it can't tell that this one has every
  transaction. Once the lost primary's leader key has expired (in up to
  30 s), `setup.sh` fails over to it. A transaction that only the other
  lost standby had confirmed is lost: an OTP of the last second or so may
  work once more.
- **Partition mode** stays on until one of the other two answers again.

```text
== alone: west
  ok    the other two answer on none of etcd's, PostgreSQL's and Patroni's ports
This makes west the cluster alone: its etcd forgets the other two servers, and its
PostgreSQL becomes the primary. Only when both are lost for good: if they still run, cut off
from here, they go on as a cluster of their own, and there are two primaries.
Make west the cluster alone? Type yes: yes
  ok    etcd: a cluster of one, west
  ..    waiting for the lost primary's leader key to expire (12 s)
  ok    Patroni: west's PostgreSQL is the primary
  ..    partition mode stays on until one of the other two answers again; then the counters of the logins in between go into the database
  ok    west is the cluster alone. Now set up the other two again: new servers with the same names and addresses, their folders, and setup.sh on both (see "Two servers lost" in the guide).
```

In the lab it took about a minute. `--yes` doesn't ask; run again, it
finds nothing to do.

**2. The other two:** set them up again as in steps 1 to 3 of
[Rebuild a turn-key server](#rebuild-a-turn-key-server), and run
`setup.sh` on both (at the same time is fine). Each adds its etcd member
as a learner, one after the other, and copies the database from the
third. Once their Patroni answers, the third leaves partition mode, and
moves the counters of the logins in between into the database, before
their anycast checks advertise.

**3. Check all three** with `setup.sh --status`, and move the primary back
to the first server, as in step 5 there.

- **While it is alone**, the third's `setup.sh --status` warns about etcd
  and Patroni, and its backups miss the counters of the logins in
  partition mode, which are only in its copy.
- `tests/radiator/turnkey.sh` loses East1 and East2, logs in through
  West from its copy, runs `--alone` on West (refused while the two run,
  without a terminal and when not answered yes; then answered yes, and
  again with `--yes`), sets up the two again at the same time, and checks
  that the OTP used on West alone is refused after.

### Replace a turn-key server

To move a server to new addresses, or to replace it with one of a new
name (when a site moves, say), the other two take the new one in: the old
server's etcd member goes, and with a new name, its anycast check and
service account too; the new server joins as a rebuilt one does.

**1. The old server,** unless it is lost: if it is the primary, move the
primary to another server first, then start it over, which stops its
services, and switch it off:

```bash
sudo patronictl -c /etc/patroni/18-main.yml switchover --candidate east2 --force   # if it is the primary
sudo /root/turnkey/setup.sh --reset NAME
```

**2. `site.toml`:** the server's new name and FQDN, or its new addresses
(and its routers, if they change), then run `yubikey-turnkey` again. It
makes the new server's certificate, and for a new name its anycast key,
and says why:

```text
yubikey-turnkey: west has new addresses, and so a new certificate (a server replaced: see the guide's "Replace a turn-key server")
```

For a new name it says that the old one's anycast key and certificate are
gone from `secrets.toml`. Give the routers' admins the new `routers.md`:
the server's routers peer with its new addresses.

**3. The two that stay:** copy their folders and run `setup.sh` on each.
Each lets the new server through its firewall, and updates `/etc/hosts`
and Patroni's settings (PostgreSQL's `pg_hba.conf`), and for a new name
Radiator's list of database servers and partition mode's peers (Radiator
restarts, so logins at that site wait a few seconds). Their etcd needs
only quorum now, and isn't restarted for the new member list:

```text
  ok    etcd: 2 of 3 members healthy (not west), with quorum
```

For a new name, the primary's `setup.sh` takes the old server's anycast
check out of the database and puts the new one's in:

```text
  ..    removed the anycast check of NAME, which isn't one of the servers now
  ..    removed the service account svc.anycast-NAME
```

**4. The new server:** steps 1 to 3 of the runbook, as for a rebuilt
one. Its `setup.sh` removes the old server's etcd member (it stops if
that one still answers: stop the old server first), and adds its own:

```text
== etcd
  ..    installed /etc/etcd/tls/ca.crt /etc/etcd/tls/server.crt /etc/etcd/tls/server.key /etc/default/etcd
  ..    etcd: removed the member of west (https://172.31.99.13:2380), which isn't one of the three servers now
  ..    etcd: added this server's member (5c25fbdaec985409), as a learner until it has caught up
  ..    etcd: promoted this server's member, which has caught up
  ok    etcd: joined the cluster; 3 members healthy
```

With a new name, its anycast check's key comes from the database, where
the primary put it in step 3.

**5. Check all three** with `setup.sh --status`. If the new server is the
first in `site.toml`, it is a standby: move the primary to it, as in step
5 of [Rebuild a turn-key server](#rebuild-a-turn-key-server).

- **Until the two that stay have run `setup.sh`**, their firewall drops
  the new server's connections, and its `setup.sh --check` warns:
  `no answer from ADDRESS on TCP 2380 within 3 s: the servers must reach each other on TCP 2379, 2380, 5432 and 8008`.
- `tests/radiator/turnkey.sh` moves West to new addresses, after
  `--reset` on it, and replaces East1, lost while it was the primary, with
  a server of a new name and addresses, which then becomes the primary.

### Rotate passwords and keys

`yubikey-turnkey --rotate` makes new passwords, secrets and keys in
`secrets.toml`, and `setup.sh` puts them in place in an order that keeps
logins and replication working:

| `--rotate` | New | Used by |
|---|---|---|
| `radiator` | Radiator's database password | Radiator on each server, and the role `radiator` |
| `patroni` | Patroni's REST API password, and the passwords of the roles `replicator` and `rewinder` | Patroni on each server (`patronictl`, replication, `pg_rewind`) |
| `admins`, `admin:LOGIN` | The admins' database passwords | The admins' `~/.pgpass`, from `admin/pgpass` |
| `localhost` | The RADIUS secret and TACACS+ key of each server's own client, `127.0.0.1` | Radiator and the anycast check on each server |
| `catch-all`, `devices`, `device:ADDRESS` | The devices' RADIUS secrets and TACACS+ keys | Radiator, and the devices (`devices.md`) |

Name several with commas, or give `--rotate` again. Not rotated: the
anycast checks' PINs and TACACS+ passwords (Radiator takes their logins
from `127.0.0.1` only, and each check renews its key by itself, every
`RENEW_DAYS` days, or now with `yubikey-anycast.sh renew`), the servers'
certificates (`--renew-certs`, in
[Change a turn-key setup](#change-a-turn-key-setup)), and the CA.

**1. Make them:**

```bash
yubikey-turnkey --rotate radiator,patroni,admins site.toml
```

```text
secrets.toml: new radiator's password, Patroni's REST API password, replicator's password, rewinder's password, opsadmin's password
...
yubikey-turnkey: new database passwords (radiator, replicator, rewinder and opsadmin): copy the folders, and run setup.sh on the primary first, which gives them to the roles; on the other two, setup.sh waits until the primary has (see the runbook, and the guide's "Rotate passwords and keys")
yubikey-turnkey: give opsadmin the new line of admin/pgpass, for ~/.pgpass
```

**2. The primary first:** copy the folders, and run `setup.sh` on the
primary. It gives the database's roles their new passwords (Patroni sets
`replicator`'s and `rewinder`'s only when it makes the cluster, so
`setup.sh` does it):

```text
== database
  ..    set radiator's new password
  ..    set replicator's new password
  ..    set rewinder's new password
  ..    set opsadmin's new password
  ok    database yubikey; roles radiator and opsadmin, with their passwords
```

Connections made before keep working, so the other two's Radiator and
replication go on with the old passwords until they change.

**3. The other two:** run `setup.sh` on each. Before Patroni or Radiator
use a new password, it checks in its own copy of the database that the
primary has given it to the role. Run on one of them before the primary,
it waits, and goes on once the primary's `setup.sh` has run:

```text
== patroni
  ..    installed /etc/patroni/18-main.yml
  ..    waiting for the primary, east1, to have the new passwords of replicator and rewinder (run setup.sh there first) (10 s)
  ok    Patroni: east1=Leader/running east2=Quorum_Standby/streaming west=Quorum_Standby/streaming
```

**4. The admins:** give each one their new line of `admin/pgpass`, for
`~/.pgpass`. `setup.sh` sets an admin's password only when `secrets.toml`
has a new one, so a password an admin changed (with `ALTER ROLE` or
psql's `\password`) stays until the next `--rotate admin:LOGIN`. The
role's comment names the one it set last.

**5. Devices:** `--rotate device:ADDRESS` (or `devices`, `catch-all`),
`setup.sh` on the three servers, in any order, then the new RADIUS secret
and TACACS+ key on the device, from `devices.md`. Radiator 4.30 takes one
secret and one key per device, so the device's logins fail from the
moment its server has the new ones until the device has them too: do it
one device at a time, with the device's admin ready, or in a maintenance
window.

`localhost` needs no order either: Radiator and the anycast check on each
server change together. The check starts again, and its server withdraws
the anycast addresses for about 10 seconds while the other two answer.

- **Logins go on.** `tests/radiator/turnkey.sh` logs in over TACACS+ at
  the anycast address every second while it rotates `radiator`,
  `patroni`, `admins` and `localhost`, with West run first: no login
  failed, or one, 1 second, when Radiator restarted on the server the
  login went to. It cuts the standbys' replication connections after the
  change, which connect again with the new password; moves the primary
  with `patronictl` and back; and checks the admin's old password
  refused, the new one working, an admin's own password kept until
  `--rotate admin:LOGIN`, and a device's old TACACS+ key refused once the
  servers have the new one.

### Upgrade a turn-key setup

One server at a time, while the other two answer: `setup.sh` restarts
only what changed on the server it runs on.

**A new release of radiator-yubikey.** Read its CHANGELOG first: new
settings in `site.toml` stay off until you add them. On the admins'
machine, run the new release's `yubikey-turnkey` with the same
`site.toml` and `secrets.toml`, and its package in the packages folder
(`-p`, with Radiator's packages as before). It keeps every secret, and
makes what the new release needs, in a line like this one (1.11.0 to
1.12.0):

```text
secrets.toml: new replicator's SCRAM verifier, rewinder's SCRAM verifier
```

From 1.12.0, there is nothing new to make, and no such line.

Copy the folders, and run `setup.sh` on the primary first (its
`yubikey-db.sh init` brings the database up to date before the other
servers' Radiator needs it), then on the other two, one at a time. Each
installs the new package with its `install.sh`:

```text
== packages
  ..    installing radiator-yubikey 1.12.1 with its install.sh (its output is in /var/log/yubikey-turnkey.log)
```

Then `setup.sh --status` on each.

**A newer Radiator** (a patch release from Radiator Software): its
packages instead of the old ones in the packages folder, `yubikey-turnkey
-p` again, copy the folders, and `setup.sh` on each server, one at a time.
It installs the newer packages over the old ones (never older ones), keeps
the server's `radiator.conf` (the package's new sample is beside it, as
`radiator.conf.dpkg-dist`), and restarts Radiator:

```text
  ..    radiator 4.30-1: replaced by the folder's 4.30-1+lab1
```

(That is the test's: Radiator 4.30-1 again, as 4.30-1+lab1.) A folder
copied over the one before keeps the old packages too; `setup.sh` takes
the newest of each.

**Ubuntu's updates.** Ubuntu Server comes with `unattended-upgrades`,
which installs the security updates by itself every day, from 06:00 to an
hour later, on each server on its own; and with `needrestart`, which
after each `apt` run restarts the services that use what it replaced.
`setup.sh` leaves both as Ubuntu has them. So after an update of
PostgreSQL (or Python), `needrestart` restarts Patroni, which restarts
PostgreSQL: on a standby, it streams again a few seconds later; on the
primary, Patroni stops PostgreSQL and another server takes over, and the
primary is then not the first server (`setup.sh --status` warns) until you
move it back. Logins go on: in the test, a TACACS+ login every second
missed none, through the planned updates and the failover. (`setup.sh`'s
own `apt-get` runs with `NEEDRESTART_MODE=l`, so that `needrestart` only
lists: `setup.sh` restarts what it installs.)

Planned updates, and a new kernel (which needs a reboot), one server at a
time, the primary last:

1. On each standby:

   ```bash
   sudo apt-get update && sudo apt-get upgrade
   sudo /root/turnkey/setup.sh --status     # OK once it streams again
   ```

   If `/run/reboot-required` exists, reboot it, and run `--status` again.
2. Move the primary to an updated standby:

   ```bash
   sudo patronictl -c /etc/patroni/18-main.yml switchover --candidate east2 --force
   ```

3. Update the old primary as in step 1.
4. Move the primary back to the first server.

Not covered yet: PostgreSQL's next major version, Ubuntu's next release,
and a new CA.

- `tests/radiator/upgrade.sh` sets up three servers with 1.12.0 (from its
  git tag), upgrades them to this version, then to a newer Radiator, and
  then updates PostgreSQL on each (with `needrestart`) as above, and on the
  primary without the switchover, as the automatic updates do, with a
  TACACS+ login every second: in three runs, one missed or none in each
  upgrade (radiator-yubikey's, Radiator's), for a second or two while
  Radiator restarted; none in the updates or the failover.

### Change a turn-key setup

- **Devices, groups to start with, admin subnets, partition mode, the
  firewall:** change `site.toml`, run `yubikey-turnkey` again (it prints
  what it wrote, and `--check` what it would write), copy the folders
  again (`scp -r out/east1/. root@east1.example.com:/root/turnkey/`), and
  run `setup.sh` on each server. A device that is gone from `site.toml`
  keeps its secret in `secrets.toml`, in case it comes back.
- **A device's existing secret or key:** put it in `secrets.toml` (8 to
  128 printable characters, without spaces, quotes, `\`, `#`, `%`, `` ` ``
  or `|`), and run `yubikey-turnkey`. Remove a value to have a new one
  made. New passwords, secrets and keys: see
  [Rotate passwords and keys](#rotate-passwords-and-keys).
- **New certificates for the servers** (they last 825 days; the tool warns
  60 days before): `yubikey-turnkey --renew-certs site.toml`, then copy the
  folders and run `setup.sh` on each server, one at a time.
- **A server's name or addresses:** see
  [Replace a turn-key server](#replace-a-turn-key-server). A server lost
  or broken is set up again with the same ones: see
  [Rebuild a turn-key server](#rebuild-a-turn-key-server).
- **Start over:** `sudo /root/turnkey/setup.sh --reset NAME` (`NAME`: the
  server's host name) stops the services and removes the server's etcd
  data, PostgreSQL cluster, anycast key and `setup.sh`'s state (the
  backups in `/var/backups` stay). Then run `setup.sh`: on this server
  alone, while the other two run, it joins them again (see
  [Rebuild a turn-key server](#rebuild-a-turn-key-server)); after
  `--reset` on all three, `setup.sh` on all three makes the database
  anew, without the YubiKeys, which a backup can bring back.

## Security

- **The database holds every user's AES key.** Anyone who can read it can
  copy the YubiKeys. The SQLite file is mode `0640`, readable by root and
  `radiator` only. In PostgreSQL, only `yubikey_admin` members and the
  `radiator` role can read the table.
- **Exports, CSV files and backups hold every AES key in clear text.**
  Encrypt them (`export - | gpg -e ...`), keep CSV files at mode `0600`, never
  commit them or attach them to tickets, and delete them with `shred -u`. The
  script warns about a CSV file that all users can read.
- **A filled-in copy of `yubikey-db-user.example.sh` holds an AES key.** Keep
  it at mode `0700`, outside the repository, and `shred -u` it when done.
- **Replace the package's sample `radiator.conf`** (it accepts every login
  from 127.0.0.1) and give every RADIUS client its own long random secret.
- **`Trace 4` writes every user's AES key and PIN hash to Radiator's log**
  (the `AuthSQLYUBIKEY read:` lines). Use it only on a test server with test
  keys, and delete the log afterwards. `radiator.example.conf` uses `Trace 3`.
- **Keep `Require2Factor`** unless you mean OTP-only logins for everyone:
  without it, the PIN is optional.
- **`/etc/radiator/conf.d/yubikey.conf` holds Radiator's database password**
  for a remote PostgreSQL: mode `0640`, owner `root:radiator`. `~/.pgpass`
  must be mode `0600`.
- **Remote PostgreSQL**: `hostssl` lines for single addresses in
  `pg_hba.conf`, `scram-sha-256` passwords, and `sslmode=verify-full` on the
  clients, so a server without your CA's certificate is refused.
- **A standby holds every AES key too**, and the `replicator` role can copy
  the whole database: protect both database servers alike, and keep
  `~postgres/.pgpass` at mode `0600`.
- **Three sites:** each server holds every AES key, so protect all three
  alike. Any certificate signed by the cluster's CA can change which server
  is the primary, through etcd: use that CA only for these three servers and
  keep `ca.key` offline. `/etc/patroni/18-main.yml` holds the replication,
  rewind and REST API passwords: mode `0640`, owner `root:postgres`.
  Patroni's REST API answers health checks without a password but takes
  commands, such as a switchover, only with it; open port 8008 only to the
  three servers and your monitoring.
- **Partition mode:** the copy, `/var/lib/yubikey-partition/keys.db`,
  holds every AES key, like the database: mode `0640`, owned by `radiator`.
  `yubikey-cluster.conf` holds Radiator's database password (mode `0640`,
  owner `root:radiator`); partition mode uses that login to copy counters
  back. See [the risks](#how-partition-mode-works) of using the copy.
- **Anycast:** `/var/lib/yubikey-anycast/key` holds a working login, the
  check's PIN and AES key, and `/var/lib/yubikey-anycast/tacacs` the
  password of its TACACS+ service account: mode `0600`, root only.
  Radiator accepts the check's users (`anycast-*`, and `svc.anycast-*` in
  `radiator-groups.example.conf`) only from 127.0.0.1, because of the
  `<Handler>` clauses for them; keep those before the ones for everyone
  else. `/etc/radiator/anycast.conf` holds the secret and TACACS+ key of
  `<Client 127.0.0.1>`: mode `0600`. Radiator's PostgreSQL role may run the
  function `anycast_renew`, which gives the key of an `anycast-*` user a new
  private ID and AES key (and nothing else); since that role can already
  read every AES key, it lets it do little more than log in as the check
  from a Radiator server. Each router accepts only the two
  anycast routes from its server. If your routers require BGP passwords,
  FRR sets them with `neighbor ADDRESS password` (the test doesn't use
  them).
- **Groups and TACACS+:** the files in `/etc/radiator/clients.d` hold every
  device's RADIUS secret and TACACS+ key: mode `0640`, owner
  `root:radiator`. Radiator 4.30's TACACS+ has no TLS, only the key's
  obfuscation: long random keys, and TACACS+ only on your management
  network. Service accounts' passwords are salted SHA-512 `{crypt}` hashes;
  in PostgreSQL, Radiator's role can read only those hashes (with the names
  and `active`) and the view `access_replies`, and change nothing in the
  group tables. Keep the two `Authorize-Only` Handlers of
  `radiator-groups.example.conf` before the others: the first works around
  Radiator answering a refused TACACS+ authorization with a packet devices
  take for an error (which some then treat as allowed), the second refuses
  `Authorize-Only` from RADIUS clients, which would otherwise get an
  account's reply attributes without a password. A RADIUS client can't send
  `YubiKey-Via`, which marks TACACS+ requests (its number can't be carried
  in a RADIUS packet).
- **Turn-key setup:** `secrets.toml` holds every password and key of the
  deployment and the cluster's CA key, and `out/` copies of them: keep both
  where only you can read them (the tool makes them mode `0600` and `0700`),
  back up `secrets.toml`, and don't send `devices.md` (every device's
  secret and key) further than needed. Each server's folder holds only
  what that server needs; the first server's also holds the anycast
  checks' keys of all three, to load them. `setup.sh` keeps a copy of the
  server's settings and secrets in `/etc/yubikey-turnkey` (root only).
  The admins' passwords reach the servers only as SCRAM verifiers. Its
  firewall leaves outgoing traffic open.
- **Automatic backups** hold every AES key, encrypted for the backups'
  certificate: only its private key decrypts them, so keep it off the
  servers, in two places, with its passphrase apart from it. The servers
  keep them readable by the group `adm`, for the admins to fetch. A
  decrypted dump holds every AES key in clear: `shred -u` it after a
  restore. `restore` brings back what the backup had, also YubiKeys or
  accounts disabled since: it lists them (`enabled again`).
  `secrets.toml.cms` is encrypted for the same certificate.
- The scripts pass AES keys and PINs to `sqlite3` and `psql` through their
  input, never on a command line, and quote every value. PINs are stored as
  salted SHA-512 `{crypt}` hashes (`-H clear` stores plain text, if something
  else must read it).

## Troubleshooting

Start with `verify` for the user: if it accepts the login and Radiator
doesn't, the problem is in Radiator's configuration or the network.

| Symptom | Cause and fix |
|---|---|
| `radpwtst` prints `No reply` | Radiator isn't running (`systemctl status radiator`), the port is wrong (`radpwtst` defaults to 1645: add `-auth_port 1812`), the client's address isn't in a `<Client>` block, or the secret is wrong. A wrong secret is dropped without a log line. |
| Radiator logs `Replay attack detected` | That OTP, or a newer one from the YubiKey, was already used. Touch the YubiKey again. |
| Radiator logs `Bad static password` | Wrong PIN, no PIN typed with `Require2Factor` set, or the user has no stored PIN while `Require2Factor` is set (Radiator always rejects an empty stored PIN). |
| Radiator logs `Bad Yubikey password` | The OTP doesn't decrypt with the stored AES key. Check with `verify`, and load the key from the `ykman` output again with `add --update`. |
| Radiator logs `Bad Yubikey Secret-Id` | The stored private ID isn't the YubiKey's. Load it again with `add --update`. |
| Radiator logs `Yubikey is not active` | The YubiKey is disabled: `enable` it. |
| Radiator logs `Yubikey secret not found in database` | No row has that username and public ID, the public ID isn't 12 characters, or Radiator can't reach the database (look for `Could not connect` above it in `radiator.log`). |
| Radiator logs `Could not connect to SQL database` | Check `DBSource`, `DBAuth`, the network and `pg_hba.conf`. With the configuration from `config`, Radiator tries again after 2 seconds (`FailureBackoffTime`); a configuration without that line waits 600 seconds, so after fixing it, `sudo systemctl restart radiator`. |
| Radiator logs `Could not connect ... session is read-only` | That server is a standby. Normal for the standby when both servers are listed. If every server says so, no server is the primary: promote the standby (see [Fail over](#fail-over)). |
| Radiator logs `No database server accepts writes: trying again in 0.5 s` | No server accepts writes, but they all answer: the primary is being switched over or restarted. Radiator holds logins for up to 5 s. If it goes on, no server is the primary: promote the standby (see [Fail over](#fail-over)), or check Patroni (three sites). |
| Radiator logs `Could not connect to any SQL database` | No listed server accepts writes. Logins are rejected (not ignored) until one does; Radiator tries again every 2 s. A configuration without `config`'s hooks adds `Request is ignored`. |
| Radiator logs `counter violation` and `Access ignored ... Database update failed` | The same OTP arrived twice at the same moment (a retransmission, two Radiator servers, or a replay attempt). The first was accepted; the second gets no answer. If it happens without a reason, find where the second request came from. Right after a `do failed for 'update yubikeys ...` line about a lost connection (in a switchover, for example), the database refused Radiator's second save of the same login: write the clause again with `config` and run `init` (see [After upgrading the scripts](#after-upgrading-the-scripts)). |
| `journalctl -u yubikey-partition` shows `copy: cannot read this server's PostgreSQL` | Normal while Patroni stops or starts PostgreSQL, for example on a former primary that is cut off; the copy is updated again when it runs. Otherwise check `sudo -u postgres psql -d yubikey`. |
| Partition mode stays on after the network is back | The primary can't be reached with Radiator's login in `yubikey-cluster.conf` (its `DBSource`, `DBAuth`, `pg_hba.conf`). See `journalctl -u yubikey-partition`; `sudo ./yubikey-partition.sh leave` shows the error. |
| Radiator logs `attempt to write a readonly database` in partition mode | `radiator` must own the copy and its folder: `sudo chown -R radiator:radiator /var/lib/yubikey-partition`. |
| `yubikey-anycast.sh check` prints `ACCEPT ..., but Radiator does not listen on 192.0.2.153 ...` | `BindAddress` doesn't list the anycast addresses, or Radiator logged `Could not bind authentication socket: Cannot assign requested address` at its start (it then runs without them): set `ip_nonlocal_bind` ([Set up anycast on each server](#set-up-anycast-on-each-server), step 2) and restart Radiator. |
| `yubikey-anycast.sh check` prints `NO REPLY within 3 s` | The `SECRET` in `/etc/radiator/anycast.conf` isn't the one of `<Client 127.0.0.1>` (Radiator drops the request without a log line). |
| `yubikey-anycast.sh check` prints `NO REPLY: Connection refused` | Radiator isn't running, or `BindAddress` doesn't list 127.0.0.1. |
| `yubikey-anycast.sh check` prints `REJECT ...: Yubikey secret not found in database` | The check's key isn't in the database (run the `enroll` line of step 5 again), or Radiator can't reach the primary. |
| `yubikey-anycast.sh check` prints `REJECT ...: Replay attack detected` | The counter file is older than the database, for example restored from a backup. The running check skips ahead by itself after a few checks; or make a new key with `enroll`. |
| `yubikey-anycast.sh check` prints `...; TACACS+ FAIL ...: No such user` | The check's service account isn't in the database, or is disabled, or none of its groups may log in to device group `localhost`: `./yubikey-db.sh -b pg access check svc.anycast-west localhost` says which. |
| `yubikey-anycast.sh check` prints `...; TACACS+ FAIL ...: Bad Password` | The database has another password for the check's service account than `/var/lib/yubikey-anycast/tacacs`. Stop the check, then `sudo ./yubikey-anycast.sh enroll-tacacs \| ./yubikey-db.sh -b pg service password svc.anycast-west`. |
| `yubikey-anycast.sh check` prints `...; TACACS+ BAD REPLY ... (wrong TACACS_KEY?)` | `TACACS_KEY` in `/etc/radiator/anycast.conf` isn't the `TACACSPLUSKey` of `<Client 127.0.0.1>`. |
| `yubikey-anycast.sh check` prints `...; TACACS+ NO REPLY: Connection refused` | Radiator has no `<ServerTACACSPLUS>` (`radiator.example.conf` has none; `radiator-groups.example.conf` has), or `BindAddress` doesn't list 127.0.0.1. |
| The check logs `cannot renew the key: the database has no function anycast_renew` | Run `./yubikey-db.sh -b pg init` once, as an admin, against the primary. |
| The check logs `cannot renew the key: psql: error: ...` | It couldn't reach the primary with Radiator's login from `yubikey-cluster.conf` (or `yubikey.conf`): check that Radiator's password is on its first `DBAuth` line. It tries again an hour later. |
| The check logs `cannot renew the key: Radiator's database ... isn't PostgreSQL` | Renewing needs PostgreSQL: replace the key by hand with `enroll` (see [Run anycast](#run-anycast)). |
| `yubikey-anycast.sh check` says `a renewal of the key isn't finished` | A renewal's answer from the database was lost. Run `sudo ./yubikey-anycast.sh renew` (with the check stopped) or start the check: either finishes it with the same key. |
| `yubikey-anycast.sh: error: net.ipv4.ip_nonlocal_bind is not 1` | Step 2 of [Set up anycast on each server](#set-up-anycast-on-each-server). |
| The check says `advertised`, but the router has no route | On the server, `sudo vtysh -c 'show bgp summary'`: a session that isn't `Established` (firewall, AS numbers, addresses), or `(Policy)`, which means a route map is missing. |
| With groups, Radiator logs `Access rejected for alice: No such user` after her YubiKey or password was accepted | None of her groups may use the device's group, or her account isn't active: `sudo ./yubikey-db.sh access check alice DEVICE_GROUP`. The device group is the `Identifier` of the `<Client>` the device matched. |
| Radiator logs `Authorization denied for alice ..., group no-access` | A TACACS+ authorization for an account that none of whose groups may use the device (any more), or that isn't active. |
| Radiator logs `Authorization denied for alice, group netadmins. No matching AuthorizeGroup rule` | The group has rules on that device group, and none matches the command: add one (`rule add`), or end the rules with `permit service=shell`. |
| Radiator logs `Inconsistent lengths in Tacacs Authentication request from ADDRESS. Bad Key?` | The device's TACACS+ key isn't the `TACACSPLUSKey` of its `<Client>`. |
| Radiator logs `Could not find a Client for ADDRESS. Falling back to default Key` | That device isn't in a `<Client>` and there is no `<Client DEFAULT>`: add it to `/etc/radiator/clients.d` and `sudo systemctl restart radiator`. |
| Radiator logs `No files to include with '/etc/radiator/clients.d/*.conf'` | No device files yet: only `<Client 127.0.0.1>` is known. |
| `yubikey-db.sh: error: ... has no service-account and group tables` | Run `init` (or `-b pg init`): it adds them. |
| `radiusd` fails with `Can't locate Cache/FastMmap.pm` | `DupCache shared` needs it: `sudo apt install libcache-fastmmap-perl`. |
| Patroni logs `CA cert does not include key usage extension` | The CA certificate has no `keyUsage`, which Python 3.13 and later require. Make the CA as in [Set up the three servers](#set-up-the-three-servers) (step 2). |
| Patroni stops with `Can not find suitable configuration of distributed configuration store` and `Available implementations: consul, kubernetes` | `python3-etcd` is missing: `sudo apt install python3-etcd`. |
| Patroni logs `Error: invalid version` when it creates the database | Debian's `pg_createcluster_patroni` takes the PostgreSQL version and cluster name from `scope`: use `scope: 18-main`. |
| A former primary stays `running` instead of `streaming`, and Patroni logs `Can not fetch local timeline and lsn from replication connection` with `does not match host name "localhost"` | Patroni can't tell whether the server must be rewound, because its replication connection to itself uses TLS. Add `use_unix_socket_repl: true` and the `local replication replicator` line (step 4 of [Set up the three servers](#set-up-the-three-servers)). |
| The primary's `pg_stat_replication` shows no standby | The standby isn't receiving changes. Check its log, its `~postgres/.pgpass` and `pg_hba.conf`'s `replication` lines. If it was offline for longer than `wal_keep_size` covers, make it a standby again from scratch. |
| A disabled user can still log in, and `active` shows `false` | The row came from the old example commands; Radiator treats the text `false` as active. Run `disable`. |
| `Log could not append ... Permission denied` | `radiusd` was run as root once. `sudo chown radiator:radiator /var/log/radiator/*`. |
| Radiator logs `attempt to write a readonly database` | `radiator` can't write the SQLite file **or its folder**. Run `sudo ./yubikey-db.sh init --owner radiator:radiator` again. |
| The first OTP works, the next ones fail | Counters aren't being saved: check the folder permissions (SQLite) and the `UpdateQuery` line. |
| `UNIQUE constraint failed` or `duplicate key` | The YubiKey is already in the database: use `--update` (or `--replace` after reprogramming). |
| `import failed and was rolled back` | Nothing was loaded. Fix the cause shown above it and import again. |
| `nothing imported; fix the rows above` | Some CSV rows are invalid: fix them, or add `--skip-invalid`. |
| `public ID ... has N characters; Radiator accepts only 12` | Program the YubiKey with a 12-character public ID. |
| `database is locked` | Radiator was writing at that moment. The script waits 5 seconds; run it again. |
| `no write access to ... (run with sudo?)` | SQLite: run the script with `sudo`. |
| `no read access to the yubikeys table ... (is X a member of yubikey_admin?)` | PostgreSQL: run `init-pg --admin X` as `postgres`, or connect as an admin. |
| `server certificate ... does not match host name` | `PGHOST` (and Radiator's `host=`) must be the name in the certificate, not an IP address. |
| `no pg_hba.conf entry for host` | Add a `hostssl` line for that address and role, and restart PostgreSQL. |
| `password authentication failed for user "radiator"` | A `DBAuth` line doesn't match the password set with `init-pg --set-password` (`config` writes three: one for each clause). |
| `setup.sh` keeps `waiting for etcd on all three servers` | Run `setup.sh` on the other servers too. If it runs there, the servers can't reach each other on TCP 2379 and 2380: a firewall on the way, or a wrong address in `site.toml`. |
| `setup.sh` keeps `waiting for the primary, NAME, to add this server's anycast check` | A server replaced, with a new name: run `setup.sh` with the new folder on the primary (see [Replace a turn-key server](#replace-a-turn-key-server)). |
| `setup.sh` says `radiator X is newer than the folder's Y: left as it is` | The folder has older Radiator packages than the server: copy a folder made with the newer ones (`yubikey-turnkey -p`), or leave it so (see [Upgrade a turn-key setup](#upgrade-a-turn-key-setup)) |
| `setup.sh` keeps `waiting for the primary, NAME, to have the new passwords of replicator and rewinder` (or `radiator's new password`) | After `yubikey-turnkey --rotate`, `setup.sh` ran here before it ran on the primary: run it on the primary, and this one goes on (see [Rotate passwords and keys](#rotate-passwords-and-keys)) |
| `setup.sh: error: etcd: the cluster has the member of NAME (URL), which isn't one of the three servers in this folder, and it runs` | The server this one replaces still runs etcd: stop it first (`setup.sh --reset NAME` on it). |
| `setup.sh` keeps `waiting for east1 to create the database` | `setup.sh` on the first server hasn't got that far, or stopped: see its output, fix the cause, and run it again there. |
| `setup.sh: error: this server's PostgreSQL isn't the primary` | The first server found another primary before it had made the database (a failover during its first run): move the primary to it with `patronictl switchover --candidate NAME --force`, and run `setup.sh` again. (Once the database is made, a first server that isn't the primary, as when rebuilt, leaves it as it is.) |
| `setup.sh: error: --alone: the others answer (TCP ...)` | One of the other two still runs, so it isn't lost: `--alone` is only for when both are lost for good. For one lost server, see [Rebuild a turn-key server](#rebuild-a-turn-key-server). |
| `setup.sh: error: etcd: the cluster has this server's member from before, and fewer than two servers run etcd` | A rebuilt server, or one after `--reset`, while one of the other two doesn't run etcd: start it there (`sudo systemctl start etcd`), and run `setup.sh` again. See [Rebuild a turn-key server](#rebuild-a-turn-key-server). |
| `setup.sh: error: an SSH connection comes from ADDRESS, outside the admin subnets` | Loading the firewall would cut that connection: add its subnet to `[admin] subnets` in `site.toml` and run `yubikey-turnkey` again, or run `setup.sh --no-firewall`. |
| `setup.sh: error: etcd on this server holds data that setup.sh didn't make`, or `PostgreSQL's cluster 18/main has databases` | `setup.sh` removes only the empty ones that the packages make. If this server may lose them, `setup.sh --reset NAME` starts it over. |
| `yubikey-turnkey: error: ... secrets.toml is readable by others` | `chmod 600 secrets.toml`. |
| `setup.sh --status`: `Patroni: the primary is east2, not east1` | After a failover. Once East1 is a `Quorum Standby` again, move the primary back: `sudo patronictl -c /etc/patroni/18-main.yml switchover --candidate east1 --force`. |
| `setup.sh --status`: `setup.sh: /root/turnkey has changed since setup.sh last finished` | A new folder was copied, but `setup.sh` hasn't run with it: run it. |
| `setup.sh --status`: `partition mode: the copy isn't updated: ...` | `yubikey-partition` can't read this server's PostgreSQL, for the reason given. Expected for a while on a primary that was cut off (Patroni stops its PostgreSQL). Otherwise see `journalctl -u yubikey-partition` and `patronictl list`. |
| `setup.sh --status`: `the check's key: the renewal of DATE hasn't worked yet` | `journalctl -u yubikey-anycast` says why; see [Run anycast](#run-anycast). The key works until `OTPs left` runs out, and it keeps trying every hour. |
| `yubikey-backup.sh status`: `the last backup failed, ...: pg_dump: error: ...` | `pg_dump` couldn't read this server's PostgreSQL, for the reason given: expected while it is down or being copied again (a standby). `sudo systemctl start yubikey-backup.service` tries again. |
| `yubikey-backup.sh status`: `the newest backup is 30 h old` (and `setup.sh --status` warns) | The timer isn't running (`systemctl status yubikey-backup.timer`; `systemctl enable --now yubikey-backup.timer`), or the runs fail (`journalctl -u yubikey-backup`). |
| `yubikey-backup.sh: FILE didn't decrypt: a wrong key, or the file isn't whole or was changed` | The file was made for another certificate (an older key pair), was cut short in a copy, or was changed. Nothing was written. Try the copy from another server. |
| `yubikey-backup.sh: cannot read the private key backup.key: a wrong passphrase` | Type the key's passphrase (the one for `backup.key`, not a server's). |
| `yubikey-backup.sh: error: this server's PostgreSQL is a standby: restore on the primary` | Run the restore on the primary (`patronictl list`, or the server whose `pg_is_in_recovery()` is false). |
| `yubikey-backup.sh: nothing restored: ... canceling statement due to lock timeout` | Another session held a lock on a table for more than 10 s (an admin's open transaction, say). Nothing changed: end it and restore again. |
| `yubikey-turnkey`: `backup.certificate: ... holds a private key` | Name the certificate (`backup.crt`) only, and keep the key off the servers and out of `out/`. |

## Reference

### `yubikey-db.sh`

```text
yubikey-db.sh [global options] <command> [command options]
```

| Global option | Environment | Default | Meaning |
|---|---|---|---|
| `-b, --backend` | `DB_BACKEND` | `sqlite` | `sqlite` or `pg` |
| `-d, --db` | `DB_FILE`, `PGDATABASE` | `/etc/radiator/db/yubicred.db`, `yubikey` | SQLite file, or PostgreSQL database name |
| `-e, --secret-encoding` | `SECRET_ENCODING` | `base64` | How AES keys are stored: `base64` or `hex` (Radiator reads both) |
| `-H, --password-hash` | `PASSWORD_HASH` | `crypt` | How PINs are stored: `crypt` (SHA-512) or `clear` |
| `-h`, `-V` | | | Help, version |

Global options go before the command. Other environment variables:
`PGHOST`, `PGPORT`, `PGUSER`, `PGSSLMODE`, `PGSSLROOTCERT`, `PGSERVICE`,
`PGCONNECT_TIMEOUT`, `PGTARGETSESSIONATTRS` (standard PostgreSQL settings;
for a server other than the local socket, `config` copies `PGHOST`, `PGPORT`,
`PGSSLMODE`, `PGSSLROOTCERT`, `PGCONNECT_TIMEOUT` (default 2) and
`PGTARGETSESSIONATTRS` into Radiator's `DBSource`; with several hosts in
`PGHOST`, `PGTARGETSESSIONATTRS` defaults to `read-write`),
`PG_ADMIN_ROLE` (default `yubikey_admin`), `PG_RADIATOR_ROLE` (default
`radiator`), `SQLITE3`, `PSQL`.

| Command | Options | What it does |
|---|---|---|
| `init` | `-o, --owner USER[:GROUP]` | SQLite: create the folder, file and table. PostgreSQL: create the table and grants in an existing database. Safe to re-run; it also brings a database made by an older version up to date. |
| `init-pg` | `-a, --admin LOGIN` (repeatable), `--set-password` | PostgreSQL, as `postgres`: create the roles and database, then `init`. |
| `add` | `-u USER`, `-P PUBLIC_ID`, `-p PRIVATE_ID`, `-k AES_KEY`, `-w PIN`, `-l LABEL`, `--no-password`, `--inactive`, `--update` or `--replace` | Add one YubiKey; asks for missing values. |
| `import` | `--dry-run`, `--skip-invalid`, `--update` or `--replace`, `--from-export`, `FILE` or `-` | Load a CSV file, or restore an export. |
| `list` | `[USER]` | Show users and YubiKeys, without secrets. |
| `verify` | `-u USER`, `--no-require2factor` | Check a PIN and OTP as Radiator would; save the counters if accepted. |
| `enable`, `disable`, `delete` | `USER [PUBLIC_ID]` | Set `active` to 1 or 0, or delete the user's rows (or one YubiKey). |
| `label` | `USER PUBLIC_ID LABEL` | Set the label of one of the user's YubiKeys: UTF-8 text, up to 255 characters, no control characters; `''` removes it. |
| `export` | `-f, --force`, `FILE` or `-` | Write every row and field to CSV (mode `0600`). |
| `config` | | Print the `<AuthBy SQLYUBIKEY>` clause (for PostgreSQL, also the clauses `YubiKeyConnect` and `YubiKeyLocal`), and the clauses `ServiceAccounts` and `GroupAccess` for [groups](#groups-and-tacacs). |
| `service add` | `NAME`, `-l LABEL`, `--inactive`, `--generate` | Add a service account (`svc.NAME`); the password is asked for twice, read from standard input, or generated. |
| `service password` | `NAME`, `--generate` | Change its password. |
| `service list`, `enable`, `disable`, `delete`, `label` | `NAME`, `LABEL` | List the accounts, turn one on or off, delete it (and take it out of its groups), or label it. |
| `group add`, `delete`, `list`, `label` | `NAME`, `-l LABEL` | Add a group, delete it (with its members, access and rules), list them, or label one. |
| `member add`, `delete` | `GROUP USER...` | Put accounts in a group, or take them out. |
| `access set` | `GROUP DEVICE_GROUP PRIV_LVL`, `-r RADIUS_REPLY` | Let the group log in to that device group (or `*`) at that privilege level, with those RADIUS reply attributes; or change them. |
| `access delete`, `list`, `check` | `GROUP DEVICE_GROUP`, `[GROUP]`, `USER DEVICE_GROUP` | Take access away (with its rules), list it, or show what an account gets on a device group (exit 1: nothing). |
| `rule add`, `delete`, `list` | `GROUP DEVICE_GROUP 'RULE'` (`--seq N`), `GROUP DEVICE_GROUP SEQ`, `GROUP DEVICE_GROUP` | TACACS+ command rules, in order. |

It exits with 0 on success and 1 on any error.

### `yubikey-db-migrate.sh`

```text
yubikey-db-migrate.sh [options] SQLITE_FILE
```

| Option | Meaning |
|---|---|
| `-d, --db NAME` | PostgreSQL database (default `yubikey`) |
| `-m, --mode new\|sync` | `new` (default): the PostgreSQL table must be empty. `sync`: add missing YubiKeys and move counters forward. |
| `-e, --secret-encoding` | How AES keys are stored in PostgreSQL (default `base64`) |
| `-n, --dry-run` | Do everything, then roll back |
| `--skip-invalid` | Copy the valid rows even if some are invalid (they are listed by user and public ID) |

### `yubikey-partition.sh`

```text
yubikey-partition.sh [-c FILE] COMMAND
```

| Command | What it does |
|---|---|
| `setup` | Make the copy, Radiator's clause for it (`yubikey-partition.conf`) and the link `yubikey.conf` -> `yubikey-cluster.conf`, moving an existing `yubikey.conf` to `yubikey-cluster.conf`. Safe to run again. |
| `run` | The service, as `yubikey-partition.service` runs it. |
| `status` | The mode and since when, the peers that answer, the copy, and where `yubikey.conf` points. Exits 0 in normal mode, 1 in partition mode. |
| `sync` | Update the copy from this server's PostgreSQL now. |
| `leave` | Leave partition mode now: copy the counters to the primary, point `yubikey.conf` back at the cluster, restart Radiator. Changes nothing if the primary can't be reached. |

`-c FILE` reads the settings from FILE instead of
`/etc/radiator/partition.conf`:

| Setting | Default | Meaning |
|---|---|---|
| `PEERS` | | The other two servers, separated by spaces |
| `PORTS` | `5432 8008` | A server answers when it accepts a connection on one of these |
| `INTERVAL` | `5` | Seconds between checks |
| `ENTER` | `3` | Checks in a row with no server answering before partition mode |
| `LEAVE` | `2` | Checks in a row with a server answering and the primary reachable before normal mode |
| `SYNC` | `300` | Seconds between updates of the copy (it is also updated when partition mode begins) |

It exits with 0 on success, 1 when a step fails, and 3 for a problem with
the settings or the setup.

### `yubikey-anycast.sh`

```text
yubikey-anycast.sh [-c FILE] COMMAND
```

| Command | What it does |
|---|---|
| `enroll` | Make a new key, PIN and user (`anycast-` and the host name) for the check, keep them in `/var/lib/yubikey-anycast/key`, and print them as CSV for `yubikey-db.sh import --replace -`. Keeps the public ID of an earlier key. Not while the check runs. |
| `enroll-tacacs` | Make a new password (32 letters and digits) for the check's TACACS+ service account (`svc.anycast-` and the host name), keep it in `/var/lib/yubikey-anycast/tacacs`, and print it for `yubikey-db.sh service add` (or `service password`), which reads it from standard input. Not while the check runs. |
| `check` | Log in once (and over TACACS+, with `TACACS_KEY`), and check that Radiator listens on the anycast addresses; exits 0 if all of it works. Not while the check runs. |
| `renew` | Give the key a new private ID and AES key, in the database (through `anycast_renew`, with Radiator's login) and in `/var/lib/yubikey-anycast/key`, as the running check does every `RENEW_DAYS` days. PostgreSQL only; not in partition mode, and not while the check runs. |
| `run` | The check, as `yubikey-anycast.service` runs it. |
| `status` | Whether the addresses are on `lo`, since when, the last check, the OTPs left, and the next renewal of the key. Exits 0 only while they are on `lo`. |
| `withdraw` | Take the addresses off `lo` (the service does this when it stops). |

`-c FILE` reads the settings from FILE instead of
`/etc/radiator/anycast.conf`. Settings (`NAME=value` lines, never run as
shell code):

| Setting | Default | Meaning |
|---|---|---|
| `ADDRESSES` | | The anycast addresses, IPv4 and IPv6, separated by spaces |
| `SECRET` | | The secret of Radiator's `<Client 127.0.0.1>` |
| `PORT` | `1812` | Radiator's authentication port |
| `INTERVAL` | `5` | Seconds between checks |
| `TIMEOUT` | `3` | Seconds to wait for Radiator's answer (at most `INTERVAL`) |
| `FALL` | `3` | Failed checks in a row that take the addresses off `lo` |
| `RISE` | `2` | Good checks in a row that put them back |
| `TACACS_KEY` | | The `TACACSPLUSKey` of Radiator's `<Client 127.0.0.1>`. When set, each check also logs in over TACACS+, and must pass both logins. |
| `TACACS_PORT` | `49` | Radiator's TACACS+ port |
| `RENEW_DAYS` | `365` | Days after which the running check renews its key (sooner if only 30 days of OTPs are left); `0`: never |

It exits with 0 on success, 1 when a check fails (`check`) or the addresses
aren't on `lo` (`status`), and 3 for a problem with the settings, the key,
the TACACS+ account's file or the system, which the service then doesn't
restart on.

### `yubikey-backup.sh`

```text
yubikey-backup.sh [-c FILE] COMMAND [OPTIONS]
```

| Command | What it does |
|---|---|
| `run` | Dump the database from this server's PostgreSQL (as `postgres`, through the local socket), encrypted for `CERT`, to `DIR/yubikey-db.cms.0`, moving the others up one and keeping `KEEP` of them. `yubikey-backup.service` runs it. |
| `status` | The newest backup and its age, how many are kept, the last run, and the certificate. Exits 0 when the newest is less than 26 hours old and the last run worked. |
| `decrypt --key KEY FILE OUT` | Decrypt `FILE` (a backup, or `secrets.toml.cms`) to `OUT` (mode `0600`), which it writes only when `FILE` is whole and unchanged, and refuses to overwrite. |
| `check [--key KEY] FILE` | Decrypt `FILE` (or take it as a dump already), read the dump back whole, and show when it was made and what it holds. Changes nothing; needs `pg_restore`, not a database. |
| `restore [--key KEY] [--yes] FILE` | On the primary: show what the restore would undo, ask (`--yes`: don't), and replace every table with the backup's in one transaction, keeping the counters that are ahead and the anycast checks' keys. |

`--key KEY` is the private key; `openssl` asks for its passphrase, or takes
it as `--passin ARG` says (`openssl`'s `-passin`: `pass:TEXT`, `env:VAR`,
`file:PATH`, `fd:N`). `-c FILE` reads the settings from FILE instead of
`/etc/radiator/backup.conf` (`restore` works without them, for the
database `yubikey`; `decrypt` and `check` don't read them):

| Setting | Default | Meaning |
|---|---|---|
| `CERT` | `/etc/radiator/backup.crt` | The certificate the backups are encrypted for (RSA) |
| `KEEP` | `7` | How many backups to keep, `.0` (the newest) to `.KEEP-1` (1 to 366) |
| `DIR` | `/var/backups` | Where |
| `DATABASE` | `yubikey` | The database |

It exits with 0 on success, 1 when a step fails (`status`: no recent
backup, or the last run failed), and 3 for a problem with the settings,
the options or the system.

### `yubikey-turnkey`

```text
yubikey-turnkey [-o DIR] [-s FILE] [-p DIR] [-n] [--renew-certs] [--rotate WHAT,...] SITE.toml
```

Checks `SITE.toml` (every error at once), makes the secrets it lacks, and
writes the folders (see [Turn-key setup](#turn-key-setup)). It removes
the files it wrote before and no longer writes; other files in the output
folder stay.

| Option | What it does |
|---|---|
| `-o DIR`, `--out DIR` | Write to `DIR` instead of `out/` next to `SITE.toml` |
| `-s FILE`, `--secrets FILE` | The secrets: `FILE` instead of `secrets.toml` next to `SITE.toml` |
| `-p DIR`, `--packages DIR` | Copy Radiator's packages (`radiator_*_all.deb` or `radiator-locked_*_all.deb`, and `radiator-radius-utilxs_*.deb`), and `radiator-yubikey_VERSION_all.deb` with `install.sh`, from `DIR` into each server's folder |
| `-n`, `--check` | Change nothing: check the input, and say what would be written or removed |
| `--renew-certs` | New certificates for the three servers; the CA stays |
| `--rotate WHAT,...` | New passwords, secrets or keys: `radiator`, `patroni`, `admins` or `admin:LOGIN`, `localhost`, `catch-all`, `devices` or `device:ADDRESS`, several with commas or `--rotate` again; then `setup.sh` on the primary first (see [Rotate passwords and keys](#rotate-passwords-and-keys)). Not with `--check` |

`SITE.toml`'s settings are in `site.example.toml`'s comments. It exits
with 0 on success (`--check`: everything is up to date), 1 when `--check`
finds something to write, and 2 for an error in the input or the options.
It needs Python 3.11 or later and `openssl`.

### `setup.sh` (`yubikey-turnkey-setup.sh`)

```text
sudo ./setup.sh [--check] [--no-firewall]
sudo ./setup.sh --status
sudo ./setup.sh --reset NAME
sudo ./setup.sh --alone [--yes]
```

In each server's folder from `yubikey-turnkey` (the package's
`yubikey-turnkey-setup.sh`). It reads `server.env`, `secrets.env`,
`files.list` and `files/` next to it.

| Option | What it does |
|---|---|
| (none) | Every step, from where it stopped; each changes only what differs |
| `-n`, `--check` | Only the preflight checks: the Ubuntu version, the host name and addresses, the clock, the disk, the packages next to it, the ports, the other servers, and SSH connections from outside the admin subnets |
| `--no-firewall` | Leave the firewall alone this time |
| `--status` | Check this server, and change nothing (see [Check a turn-key server](#check-a-turn-key-server)); without the folder (as `/opt/radiator-yubikey/yubikey-turnkey-setup.sh`), with the copy of `server.env` in `/etc/yubikey-turnkey` |
| `--reset NAME` | Stop the services, and remove this server's etcd data, PostgreSQL cluster, anycast key and state (`NAME`: its host name); the backups in `/var/backups` stay. Then `setup.sh` on this server alone joins the other two again; after `--reset` on all three, it makes a new cluster |
| `--alone` | Only when the other two servers are lost for good: make this server the cluster alone, its etcd a cluster of one with its data, and its PostgreSQL the primary (see [Two servers lost](#two-servers-lost)). It refuses while one of them answers, and asks first |
| `--yes` | With `--alone`: don't ask |

`TURNKEY_WAIT` sets how long it waits for the other servers (default 1800
seconds). It exits with 0 when the server is set up (`--check`: nothing to
fix), 1 when something failed (`--check`: something to fix), and 2 for a
usage error. `--status` exits with 0 (`OK`), 1 (`WARNING`), 2 (`CRITICAL`)
or 3 (`UNKNOWN`: not as root, or no `server.env`).

### `install.sh`

```text
sudo ./install.sh [OPTIONS] [PACKAGE.deb]
```

Checks that Radiator is installed, then installs PACKAGE.deb with the
packages that it and Radiator's YubiKey support need (see
[The radiator-yubikey package](#the-radiator-yubikey-package)).
PACKAGE.deb defaults to the newest `radiator-yubikey_*_all.deb` next to
`install.sh`; without one, it installs the other packages only.

| Option | Meaning |
|---|---|
| `-y, --yes` | Go on without asking when Radiator is not found |
| `-n, --check` | Change nothing: show what is installed, what is missing and what is left to do (needs no root) |
| `--radiusd FILE` | Radiator's `radiusd`, when it is not in `/opt/radiator/radiator` or on the `PATH` |

It exits with 0 when done (with `--check`, when nothing is missing or left
to do), 1 for an error (with `--check`, when something is missing or left to
do), 2 for a wrong option, and 3 when it stopped because Radiator is not
installed.

### `packaging/build-deb.sh`

```text
packaging/build-deb.sh [OUTDIR]
```

Builds the package, `radiator-yubikey_VERSION_all.deb`, in OUTDIR (default
`dist/`), from the files that `packaging/debian/radiator-yubikey.install`
names, and writes `install.sh` next to it, as a release has it. VERSION is
the one in the file `VERSION`, and the package's date is that of the version
in `CHANGELOG.md`, so the same files always build the same package, byte for
byte. The package's scripts, and that `install.sh`, have the version written
in, so that each also runs on its own; a script from the repository that has
no `VERSION` file next to it shows its version as `unknown`. It needs
`dpkg-dev` and `debhelper` (`sudo apt install dpkg-dev debhelper`).

### `tests/make-otp.sh`

```text
tests/make-otp.sh PUBLIC_ID PRIVATE_ID AES_KEY COUNTER [SESSION]
```

Prints the OTP a YubiKey with those values would type. Each OTP must have a
higher counter (or the same counter and a higher session) than the last one
used. It passes the AES key to `openssl` on its command line: test keys only.

### Database layout

The table is `yubikeys`, one row per YubiKey:

| Column | SQLite | PostgreSQL | Contents |
|---|---|---|---|
| `username` | `varchar(255)` | `varchar(255)` | The login name; indexed, not unique |
| `password` | `varchar(64)` | `text` | PIN: `{crypt}$6$...`, plain text, or empty |
| `active` | `boolean` | `smallint`, 0 or 1 | 1 allows logins; Radiator treats only 0 or empty as disabled |
| `created` | `datetime` | `timestamptz` | When the row was added (UTC) |
| `accessed` | `datetime` | `timestamptz` | Last successful login; empty until then |
| `tokenId` | `varchar(60)` | `varchar(60)` | Public ID (modhex); unique |
| `userId` | `varchar(60)` | `varchar(60)` | Private ID (hex); primary key |
| `secret` | `varchar(60)` | `varchar(60)` | AES key, base64 (or hex) |
| `counter`, `low`, `high` | `int` | `integer` | The replay counters (`low` is the session counter; Radiator sets `high` to 0) |
| `label` | `varchar(255)` | `varchar(255)` | Describes the YubiKey, for people; empty for none. Radiator doesn't read it. Added in 1.8.0. |
| `login_id` | | `varchar(64)` | PostgreSQL only: the ID of the Radiator login that last saved the counters, kept by the trigger; empty after a save by the scripts. Added in 1.9.0. |

PostgreSQL roles: `yubikey_admin` owns the database and table; its members
manage users. `radiator` can `SELECT` username, password, active, tokenId,
userId, secret and the counters, and `UPDATE` only accessed and the counters;
it can't read the labels, nor read or write `login_id`.

In both databases, the trigger `yubikeys_counters_forward` refuses an
`UPDATE` of `counter` or `low` that doesn't move them forward, with the error
`counter violation: ... already used this OTP or a later one`. To reset a
YubiKey's counters on purpose, replace its row (`add --replace`).

In PostgreSQL, the trigger lets one kind of such save through: the same
login saving the same counters again. Radiator does that when the answer to
its first save was lost, as when the primary stops while the save waits for
the standby (the save was made, but the connection dropped). Radiator's
`UpdateQuery` names the login, with the random ID `YubiKeyConnect` gives it
(`set_config('yubikey.login_id', ...)`, for that save only), and the trigger
keeps the ID in `login_id`. A save that names no login, from the scripts or
from a clause written by `config` before 1.9.0, empties `login_id`. Two
logins with the same OTP have different IDs, so the second is still refused.

In PostgreSQL, the function `anycast_renew(public ID, private ID, new
private ID, new AES key)` (added in 1.10.0) is how the
[anycast check](#run-anycast) renews its key with Radiator's login. It runs
with the rights of its owner, `yubikey_admin`, and `radiator` may run it.
It replaces only the row of an `anycast-*` user with that public ID and
private ID, by a row with the new private ID and AES key (stored as hex or
base64, as the row's was), the same username, PIN, public ID and label, and
counters at 0. It answers `true` when the row has the new key, also when
called again after the answer was lost, and `false` when there is no such
row.

The service accounts and groups (added in 1.10.0; `init` adds them to an
older database) are in five more tables, the same in both databases but for
the types of times and `active`:

| Table | Columns | Contents |
|---|---|---|
| `service_accounts` | `username` (key), `password`, `active`, `created`, `changed`, `label` | Service accounts: `svc.NAME`, a `{crypt}` hash, 1 or 0, when added and when the password was last set |
| `user_groups` | `name` (key), `label` | Groups |
| `group_members` | `user_group`, `username` | Who is in each group: YubiKey users and service accounts, by username |
| `group_access` | `user_group`, `device_group`, `priv_lvl`, `radius_reply` | The device groups each group may use (`*`: every one), at privilege level 0 to 15, with RADIUS reply attributes |
| `group_rules` | `user_group`, `device_group`, `seq`, `rule` | TACACS+ command rules for an access, tried in `seq` order |

The view `access_replies` has one row for each active account, group it is
in and device group that group may use, with the RADIUS reply and the
TACACS+ rules Radiator returns (`OSC-Authorize-Group` attributes: the
privilege level first, then the rules, or `permit service=shell` when there
are none). `GroupAccess` takes the row with the highest privilege level for
the user and the device's group (or `*`). In PostgreSQL, Radiator's role may
read only the view and the service accounts' `username`, `password` and
`active`.

### Export format

`export` writes the header
`username,public_id,private_id,aes_key,password,active,created,accessed,counter,low,high,label`
and one row per YubiKey: AES keys as 32 hex characters, PINs as stored, times
in UTC, and fields with a comma, quote or line break quoted. Only
`import --from-export` reads it. It also reads exports made before 1.8.0,
which have no `label` column; with `--replace`, the YubiKeys in them keep
the labels they have.
`export` doesn't include the service accounts and groups: back them up with
the database itself (see [Backups](#backups)).

### How Radiator 4.30 checks a login

Read from Radiator 4.30's source (`Radius/AuthYUBIKEYGENERIC.pm`) and
confirmed with real logins (`tests/radiator/run.sh`). `verify` follows the
same steps.

1. The login is `PIN:` (optional), a 12-character public ID, and the
   32-character token; `PIN` may also come right before the OTP without a
   colon. Any other public ID length is never found.
2. The row is found by username and public ID (`%0` and `%3` are quoted).
3. The YubiKey is rejected if `active` is 0 or empty. Any other value,
   including the texts `true` and `false`, and NULL, counts as active.
4. The PIN is checked if one was typed, or always with `Require2Factor`. An
   empty stored PIN never matches. `{crypt}`, `{SSHA}`, `$6$` and other common
   formats, and plain text, are accepted.
5. A `secret` of 32 hex characters is read as hex, anything else as base64.
   The token must decrypt with a valid CRC.
6. With `CheckSecretId`, the token's private ID must equal `userId` exactly
   (lowercase hex).
7. The top bit of the usage counter (set when the OTP was triggered from a
   keyboard key) is ignored. The OTP is a replay unless its counter is above
   the stored `counter`, or equal with a session counter above `low`. A NULL
   counter skips this check.
8. `UpdateQuery` saves the counter, the session counter (`low`), 0 (`high`)
   and the time. If the save fails, Radiator ignores the request (no
   answer) with `Database update failed`. That is what happens to the second
   of two logins with the same OTP at the same moment: both pass the check in
   step 7 before either saves, and the database refuses the second save.
   When a save fails because the connection dropped, Radiator connects
   again and repeats the same save; in PostgreSQL the trigger accepts the
   repeat if the first save was made.

## Testing

`tests/run-tests.sh` runs the scripts through 49 scenarios against throwaway
SQLite and PostgreSQL databases and compares each transcript (commands,
output, exit codes, and the final table) with `tests/expected/`, where the
scripts' version shows as `<VERSION>`. The two `anycast` scenarios run
`yubikey-anycast.sh` against a stand-in RADIUS server, which checks each
request the way Radiator does, a stand-in TACACS+ server, and stand-ins for
`ip` and `ss`; `pg_anycast` renews the check's key in the test's
PostgreSQL, with Radiator's login. `pg_partition` runs `yubikey-partition.sh` with the test's
PostgreSQL as both the local database and the primary, a stand-in for
`systemctl`, and a peer that is a port that listens or doesn't. `groups`
and `pg_groups` also run Radiator's `GroupAccess` query from `config` on
the database (on PostgreSQL, as Radiator's role). `install`
runs `install.sh` with stand-ins for `apt-get`, `dpkg-query` and Radiator,
installed in each of the ways it recognizes. `turnkey` runs
`yubikey-turnkey` on `site.example.toml` with fixed secrets
(`tests/turnkey/example-secrets.toml`) and shows everything it writes;
`turnkey_errors` its checks of the input, `turnkey_secrets` the
secrets it makes, and changed by hand, and `turnkey_rotate` what each
`--rotate` makes anew (and nothing else). `backup` runs `yubikey-backup.sh`'s
settings, `status` and `decrypt` (of whole, changed and cut files), and
`pg_backup` its backups, checks and restores in the test's PostgreSQL,
with the test key pair in `tests/turnkey/` (passphrase `test-only`). It needs `bash`, `sqlite3`,
`perl`, and, for the `verify` and `anycast` scenarios, `openssl` and
`libcrypt-rijndael-perl` (`dpkg-deb` for `install`, and Python 3.11 and
`openssl` for the `turnkey` ones); it runs as a normal user.

```bash
tests/run-tests.sh                 # every scenario
tests/run-tests.sh add verify      # some scenarios
tests/run-tests.sh --update        # accept a deliberate change; then review it with git diff
```

The `pg_*` and `migrate_*` scenarios need a PostgreSQL 18 server you can reach
as a role with `CREATEDB` and `CREATEROLE`
(`sudo -u postgres createuser --createdb --createrole "$USER"`); without one
they are skipped. They create and drop databases and roles named
`yk_test_<pid>_*`.

`tests/radiator/run.sh DIR` tests against Radiator itself, in containers
built from the Radiator packages in `DIR` (see
[The automated test](#the-automated-test)).

### Which tests a change needs

`tests/run-tests.sh` (about 3 minutes) and `shellcheck -x` on the scripts
run for every change. The seven labs of `tests/radiator/run.sh` take about
65 minutes together (`turnkey.sh` half of it), so a change runs the labs
that use what it changed, and a release, or a new Radiator version, runs
all seven:

| What changed | Labs |
|---|---|
| `yubikey-db.sh`'s commands, `yubikey-db-migrate.sh`, `yubikey-db-user.example.sh` | `e2e`; `turnkey` too for the commands `setup.sh` runs (`init-pg`, `import`, `delete`, and those for groups, members, rules, access and service accounts) |
| `yubikey-db.sh config` (Radiator's clauses and hooks), `radiator.example.conf`, `dictionary.yubikey` | `e2e`, `groups`, `ha`, `geo`, `turnkey` |
| The groups: `radiator-groups.example.conf`, and their queries in `config` | `groups`, `turnkey` |
| The database's tables | all seven |
| `yubikey-anycast.sh` | `e2e`, `groups`, `geo`, `turnkey` |
| `yubikey-partition.sh`, `yubikey-backup.sh` | `geo`, `turnkey` |
| `install.sh` | `package`, `turnkey`, `upgrade` |
| `packaging/`, the systemd units | `package`, `geo`, `turnkey`, `upgrade` |
| `yubikey-turnkey`, `yubikey-turnkey-setup.sh` | `turnkey`; `upgrade` too when it changes what `setup.sh` installs, or how a server is upgraded |
| A lab's script | that lab; `turnkey-lib.sh`: `turnkey` and `upgrade`; `run.sh`, `Dockerfile`: all seven |
| Only this guide, `README.md` or `CHANGELOG.md` | none (rebuild `yubikey-db-guide.html`) |

For example, a change to how `setup.sh` installs packages:

```bash
tests/run-tests.sh && shellcheck -x *.sh tests/*.sh tests/radiator/*.sh
tests/radiator/run.sh ~/radiator-packages turnkey upgrade   # about 40 minutes
```

## References

- [Radiator reference: `<AuthBy SQLYUBIKEY>`](https://files.radiatorsoftware.com/radiator/ref/AuthBySQLYUBIKEY.html)
- [Radiator reference: `AuthSelect` for SQLYUBIKEY](https://files.radiatorsoftware.com/radiator/ref/AuthSelect_AuthBySQLYUBIKEY.html)
- The Radiator distribution's `goodies/yubikey.cfg` and `goodies/yubikey.txt`
- [YubiKey Manager (`ykman`) documentation](https://docs.yubico.com/software/yubikey/tools/ykman/)
- [PostgreSQL 18: SSL support](https://www.postgresql.org/docs/18/ssl-tcp.html) and
  [the pg_hba.conf file](https://www.postgresql.org/docs/18/auth-pg-hba-conf.html)
- [PostgreSQL 18: log-shipping standby servers](https://www.postgresql.org/docs/18/warm-standby.html),
  [`pg_basebackup`](https://www.postgresql.org/docs/18/app-pgbasebackup.html) and
  [libpq connection strings with several hosts](https://www.postgresql.org/docs/18/libpq-connect.html#LIBPQ-MULTIPLE-HOSTS)
