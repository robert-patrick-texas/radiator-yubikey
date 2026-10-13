# YubiKey OTP on Radiator with SQLite or PostgreSQL

A how-to guide for offline YubiKey one-time-password (OTP) logins on
[Radiator](https://radiatorsoftware.com/) RADIUS, with the YubiKeys kept in a
local SQLite database or a shared PostgreSQL database, managed with the scripts
in this repository. It covers a lab you can build in a container, a server
installation, adding accounts, checking credentials, day-to-day maintenance,
moving from SQLite to PostgreSQL, a second PostgreSQL server that takes over
when the first fails, three sites with automatic failover, and one anycast
address for all of them.

The scripts, this guide and the releases are on GitHub:
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
14. [Anycast](#anycast)
15. [Security](#security)
16. [Troubleshooting](#troubleshooting)
17. [Reference](#reference)
18. [Testing](#testing)
19. [References](#references)
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
| `yubikey-db.sh` | Creates the database, adds, updates, lists, disables and deletes users and YubiKeys, checks a password and OTP (`verify`), exports and restores, and prints the Radiator configuration. SQLite by default, PostgreSQL with `-b pg`. |
| `yubikey-db-migrate.sh` | Copies everything from the SQLite database into PostgreSQL, verified row by row, and keeps counters in step during a cutover. |
| `yubikey-db-user.example.sh` | An example wrapper that adds or updates one test account from variables at the top of the file. |
| `radiator.example.conf` | A Radiator configuration for YubiKey logins, to replace the package's sample. |
| `yubikey-anycast.sh` | Puts the anycast addresses on the loopback interface, for FRR to advertise, only while the local Radiator accepts logins (see [Anycast](#anycast)); with `yubikey-anycast.service` and `yubikey-anycast.example.conf`. |
| `users.example.csv` | A sample bulk-import file (test values only). |
| `tests/make-otp.sh` | Makes the OTP a YubiKey with given values would type, for tests without a YubiKey. |
| `tests/radiator/` | Builds a container with Radiator and runs real logins against both databases. |

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

- **Radiator packages from Radiator Software**, for Ubuntu 26.04. This guide
  uses `radiator_4.30-1_all.deb` and
  `radiator-radius-utilxs_2.4-4.resolute_amd64.deb`. The `radiator` package
  needs no license file; a `radiator-locked` package needs
  `/etc/radiator/license.conf` from Radiator Software.
- **Ubuntu 26.04 LTS** for the Radiator server and, for PostgreSQL, a
  **PostgreSQL 18** server (Ubuntu 26.04's default).
- **YubiKeys** with a free OTP slot, and
  [YubiKey Manager](https://www.yubico.com/support/download/yubikey-manager/)
  (`ykman`) on a trusted workstation to program them.
- For the lab and the automated test: **Docker**, usable without `sudo`
  (membership of the `docker` group).

| Machine | Packages |
|---|---|
| Radiator server | The Radiator packages, `libauth-yubikey-decrypter-perl`, `libcrypt-rijndael-perl`, `libcache-fastmmap-perl`, and `libdbd-sqlite3-perl` + `sqlite3` (SQLite) or `libdbd-pg-perl` + `postgresql-client` (PostgreSQL) |
| Where you run the scripts (usually the Radiator server) | `bash`, `perl`, `sqlite3` or `postgresql-client`; `libcrypt-rijndael-perl` for `verify` |
| PostgreSQL server (if separate) | `postgresql` |
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
`/opt/yubikey-db`. You work as root inside it, so the commands below have no
`sudo`:

```bash
docker run -it --rm --name yk-lab -v "$PWD:/opt/yubikey-db:ro" -w /opt/yubikey-db radiator-yubikey-lab bash
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
added, and runs three tests of real Radiator logins:

- `e2e.sh`, 92 checks in a throwaway container: SQLite with and without
  `Require2Factor`, PostgreSQL over the local socket and over TLS, the example
  wrapper, a cutover from SQLite to PostgreSQL while Radiator runs, and the
  same OTP sent twice at the same moment to two of Radiator's farm processes
  (accepted twice without the trigger, once with it). For each login it
  checks Radiator's answer and the reason it logs, and that `verify` agrees.
- `ha.sh`, 56 checks with four containers: two PostgreSQL servers (primary
  and streaming standby, over TLS) and two Radiator servers, through a dead
  primary, a hung primary, failovers, an old primary coming back, a
  planned switchover, the replay window (see
  [Two database servers](#two-database-servers)), and the same OTP sent to
  both Radiator servers at the same moment.
- `geo.sh`, 134 checks with three containers, one per site, each running
  systemd with etcd, PostgreSQL under Patroni, Radiator, FRR and
  `yubikey-anycast.sh`, set up as in [Three sites](#three-sites) and
  [Anycast](#anycast), with traffic control adding the WAN delays (55 ms
  between West and East, 4 ms between the East sites). A fourth container
  stands in for West's router (FRR), and a fifth, behind it, is a RADIUS
  client that logs in at the anycast addresses, over IPv4 and IPv6. It
  measures login times, then stops West's Radiator and West's check, reboots
  each server in turn, cuts West's and then the primary's power, kills
  Patroni on the primary, cuts West off, cuts the primary's site off,
  breaks the link between the East sites, copies a standby again, and takes
  two servers down at once. Each time it checks which logins are accepted,
  that no OTP accepted before is accepted again, that the cluster recovers,
  which servers the router has anycast routes from, and which server
  answers the client. The containers have the `SYS_ADMIN` capability (for
  systemd) and `NET_ADMIN` (for traffic control and addresses in their own
  network), but aren't privileged. Docker sets the two kernel settings of
  [Set up anycast on each server](#set-up-anycast-on-each-server), step 2,
  in the containers (`--sysctl`); the step's commands themselves were run in
  a container whose kernel settings it could change for its own network
  only.

```bash
tests/radiator/run.sh ~/radiator-packages        # all three, about 13 minutes
tests/radiator/run.sh ~/radiator-packages ha     # only ha.sh (or e2e, or geo)
```

Each prints one `PASS` or `FAIL` line per check and ends with a count, such as
`Radiator 4.30-1: 92 passed, 0 failed`,
`Two database servers: 56 passed, 0 failed` and
`Three sites: 134 passed, 0 failed`. Run them again with each new
Radiator version. `KEEP=1 tests/radiator/ha.sh yk-radiator-test:4.30-1` (or
`geo.sh`) leaves the containers running afterwards, to look around.

## Install on the servers

### Radiator server

Install Radiator, the Perl modules its YubiKey support needs, and the
database driver you use:

```bash
sudo apt install ./radiator_4.30-1_all.deb ./radiator-radius-utilxs_2.4-4.resolute_amd64.deb \
                 libauth-yubikey-decrypter-perl libcrypt-rijndael-perl libcache-fastmmap-perl
sudo apt install libdbd-sqlite3-perl sqlite3          # SQLite
sudo apt install libdbd-pg-perl postgresql-client     # PostgreSQL
```

The package creates the `radiator` user, installs Radiator in
`/opt/radiator/radiator` (its tools, such as `radpwtst`, aren't on the
`PATH`), and adds the `radiator.service` systemd unit, which runs Radiator as
`radiator` with `/etc/radiator/radiator.conf`. Check the modules:

```bash
perl -MAuth::Yubikey_Decrypter -MCrypt::Rijndael -MDBD::SQLite -e 'print "ok\n"'   # or -MDBD::Pg
```

### The scripts

Put the scripts where admins can run them, for example `/opt/yubikey-db`:

```bash
sudo git clone https://github.com/robert-patrick-texas/radiator-yubikey.git /opt/yubikey-db
cd /opt/yubikey-db
```

The examples in this guide run from that directory. With SQLite, run the
scripts with `sudo`, because the database belongs to `radiator`. With
PostgreSQL, run them as yourself, as a member of the admin role (set up in
[Create the database](#create-the-database)); `export DB_BACKEND=pg` in your
`~/.profile` saves typing `-b pg` every time.

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
`DBAuth` line (`sudoedit /etc/radiator/conf.d/yubikey.conf`). This is why the
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
</AuthBy>
```

- `AuthSelect` finds the row by both the username and the public ID, so a
  user can have several YubiKeys and one user's YubiKey can't log in as
  another user.
- `UpdateQuery` saves the counters after each login. For PostgreSQL it uses
  `to_timestamp(%5)`, because Radiator's default `current_timestamp()` isn't
  valid there.
- `CheckSecretId` checks the private ID inside the OTP against the database.
- `Require2Factor`: see below.
- For PostgreSQL, `config` also writes `Timeout 2`, `ConnectTimeout` and
  `FailureBackoffTime 10`, so Radiator gives up quickly on a database server
  that doesn't answer and tries again after 10 s, not 600 s (see
  [Configure Radiator for two servers](#configure-radiator-for-two-servers)).

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
YubiKeys. Each command below is for SQLite; add `-b pg` (or set
`DB_BACKEND=pg`) for PostgreSQL, and leave out `sudo` there.

### One account

`add` asks for each value you leave out; the private ID, AES key and PIN
aren't shown as you type:

```bash
sudo ./yubikey-db.sh add                              # asks for everything
sudo ./yubikey-db.sh add -u alice -P vvccccbbcdef     # asks for the private ID, key and PIN
sudo ./yubikey-db.sh add -u kiosk -P vvccccbbcdeh --no-password
```

PINs are stored as salted SHA-512 `{crypt}` hashes. Options `-k` (AES key)
and `-w` (PIN) also exist, but other users can see them in `ps` and they stay
in your shell history, so let the script ask instead.

If the YubiKey may already be in the database, add `--update` (see
[Update and replace](#update-and-replace)).

### Many accounts from a CSV file

```csv
username,public_id,private_id,aes_key,password,active
alice,vvccccbbcdef,4a6f8e2d1c3b,6b1f0a9d2c7e4f3a8b5d0c1e9f2a7b6d,1234,1
bob,vvccccbbcdeg,9e8d7c6b5a41,0f1e2d3c4b5a69788796a5b4c3d2e1f0,5678,yes
```

| Column | Required | Format |
|---|---|---|
| `username` | Yes | The RADIUS login name: letters, digits and `. _ @ + -` |
| `public_id` | Yes | 12 modhex characters |
| `private_id` | Yes | 12 hex characters (12 modhex characters are converted to hex) |
| `aes_key` | Yes | 32 hex characters; spaces and colons are removed |
| `password` | No | The PIN; empty for none |
| `active` | No | `1`/`0`, `true`/`false`, `yes`/`no`; default `1` |

The header row is optional; blank lines and lines starting with `#` are
skipped; Windows line endings are accepted; spaces and double quotes around
a field are removed; **fields can't contain commas**.

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
                        # and db_backend, db_name and require2factor if not the defaults
sudo ~/yk-user.sh       # SQLite; for PostgreSQL run it as yourself
shred -u ~/yk-user.sh   # when done
```

The YubiKey's public ID decides which record is meant; other YubiKeys of the
user are left alone. The PIN can't contain a comma, start or end with a space,
or be in double quotes.

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
the AES key or private ID. An accepted OTP's counters are saved, as Radiator
saves them.

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

Add `-b pg` for PostgreSQL. `list` never shows AES keys or PINs.

| Task | Command |
|---|---|
| List all users and YubiKeys | `sudo ./yubikey-db.sh list` |
| Show one user | `sudo ./yubikey-db.sh list alice` |
| Check a user's PIN and OTP | `sudo ./yubikey-db.sh verify -u alice` |
| Change a PIN (counters kept) | `sudo ./yubikey-db.sh add --update -u alice -P vvccccbbcdef` |
| Give a user another YubiKey | `sudo ./yubikey-db.sh add -u alice -P vvccccbbcdeg` |
| Suspend a user (all their YubiKeys) | `sudo ./yubikey-db.sh disable alice` |
| Suspend one lost YubiKey | `sudo ./yubikey-db.sh disable alice vvccccbbcdef` |
| Turn a user back on | `sudo ./yubikey-db.sh enable alice` |
| Remove one YubiKey | `sudo ./yubikey-db.sh delete alice vvccccbbcdef` |
| Remove a user | `sudo ./yubikey-db.sh delete alice` |
| Back up everything, encrypted | `sudo ./yubikey-db.sh export - \| gpg -e -r backup@example.com > yubikeys.csv.gpg` |
| Restore a backup | `gpg -d yubikeys.csv.gpg \| sudo ./yubikey-db.sh import --from-export -` |

### Update and replace

`add` and `import` refuse a YubiKey that is already in the database. Two
options change that:

| | `--update` | `--replace` |
|---|---|---|
| Same YubiKey (same public ID, private ID and AES key) | Username, PIN and `active` updated; **counters and times kept** | Replaced; counters reset to 0 |
| Reprogrammed YubiKey (same public ID, new private ID or AES key) | Replaced; counters reset to 0 | Replaced; counters reset to 0 |
| New YubiKey | Added | Added |

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
takes a consistent copy while Radiator runs; for PostgreSQL, use `pg_dump`.
Every backup holds every AES key: keep it encrypted.

### After upgrading the scripts

Run `init` again (`sudo ./yubikey-db.sh init --owner radiator:radiator`, or
`./yubikey-db.sh -b pg init` as an admin). It adds what a newer version needs
to an existing database and changes nothing else. Version 1.2.1 adds the
trigger that stops the same OTP being accepted twice at the same moment (see
[Database layout](#database-layout)). With two database servers, run it
once, against the primary; the standby gets the change by replication.

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

`yubikey-db-migrate.sh` copies every user and YubiKey, **with their counters**,
from the SQLite database into an empty PostgreSQL database, in one
transaction. It reads a consistent snapshot, so Radiator keeps running on
SQLite meanwhile, and commits only after checking every copied row against an
independent SHA-256 fingerprint of the snapshot. Rows from the old example
commands are normalized and each change is reported (for example, an
`active` of `false` becomes 0, and the report warns that those YubiKeys could
log in before).

The account that runs it must be a member of `yubikey_admin` and able to read
the SQLite file, for example by joining the `radiator` group
(`sudo usermod -aG radiator "$USER"`, then log in again).

1. Create the PostgreSQL database (see
   [Create the database](#create-the-database)):
   `sudo -u postgres ./yubikey-db.sh -b pg init-pg --admin "$USER"`.
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
   (without changing) rows that differ in username, PIN, `active` or key.

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
| The primary died or hangs, and the standby isn't promoted yet | It **rejects** every login with `Yubikey secret not found in database`. The first login after the failure takes 2 to 5 s (up to 2 s waiting for a query, plus up to 2 s for each server that doesn't answer), and so may the first one in each of Radiator's four farm processes. A process that has seen the failure rejects at once for the next 10 s (`FailureBackoffTime`) without trying, then tries again. |
| The standby has been promoted | Logins work again within 10 s. |
| A Radiator server's connection to the old primary ended, and a writable server exists | It reconnects and answers the same login: nothing is rejected. |
| An OTP used before the failure | Still rejected as a replay, unless it was used in the replay window. |

Radiator rejects logins while no server accepts writes; it doesn't stay
silent. Its log says `Request is ignored`, but the YubiKey check returns a
reject. Network devices that try their local accounts only when no RADIUS
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
sudoedit /etc/radiator/conf.d/yubikey.conf     # put Radiator's password on the DBAuth line
sudo systemctl restart radiator
```

`config` writes:

```apache
    DBSource     dbi:Pg:dbname=yubikey;host=db1.example.com,db2.example.com;port=5432;sslmode=verify-full;sslrootcert=/etc/radiator/pg-ca.crt;connect_timeout=2;target_session_attrs=read-write
    DBUsername   radiator
    DBAuth       RADIATOR-PASSWORD

    Timeout             2
    ConnectTimeout      5
    FailureBackoffTime  10
```

- `target_session_attrs=read-write` skips the standby, which only accepts
  reads. A server that doesn't answer is skipped too.
- `connect_timeout=2` gives up on a server that doesn't answer after 2 s.
  `ConnectTimeout` (Radiator's limit for the whole connection attempt) must
  be longer than that times the number of servers.
- `Timeout 2` gives up on a query after 2 s. Radiator's default is 60 s, and
  Radiator answers nothing else while it waits.
- `FailureBackoffTime 10`: when no server accepts writes, Radiator rejects
  logins without trying for 10 s, then tries again. Its default is 600 s,
  which would leave logins failing for 10 minutes after the standby is
  promoted.

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

Logins are rejected from step 1 until a few seconds after step 2 (up to
`FailureBackoffTime`).

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
with those delays (see [Testing](#testing)).

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
| East1 (the primary) reboots | Rejected for about 6 s, while Patroni stops PostgreSQL and East2 takes over. No OTP is lost. |
| A planned switchover | Rejected for about 5 s. No OTP is lost. |
| East1 loses power | Rejected for about 35 s, until the lease expires and East2 is promoted. No OTP is lost. |
| Patroni crashes on the primary | Nothing: systemd starts it again, and it keeps the lease. |
| West is cut off from both East sites | No change at the East sites. At West, every login is rejected (`Yubikey secret not found in database`) after 4 to 6 s, until the network is back. West stays a standby and catches up within a minute afterwards. |
| East1's site is cut off from the others | At East1: no answer at first, then rejected. Elsewhere: rejected for about 45 s, then East2 is the primary. |
| The link between East1 and East2 fails | Logins at East1 and West work; East1's take about 85 ms, because West now confirms them. At East2 they are rejected until the link is back. |
| East2 and West down at once | East1 alone has no majority and stops being the primary: every login is rejected until one of them is back. |

As with two servers, Radiator rejects logins while it can't reach a primary;
network devices that try their local accounts only when no RADIUS server
answers won't fall back to them. (With [anycast](#anycast), a site that
can't log anyone in stops answering instead.) Logging in at a site that can reach no
primary, such as West when it is cut off, would need a copy of the keys on
that site, which this setup doesn't have.

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
sudoedit /etc/radiator/conf.d/yubikey.conf     # put Radiator's password on the DBAuth line
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

## Anycast

With anycast, every Radiator server has the same IPv4 and IPv6 address on
its loopback interface, and **FRR** advertises it to the site's router with
BGP. The network devices are given that one address as their RADIUS server
and reach their own site's server. When a server can't log anyone in, it
stops advertising the address, and its site's devices reach another site.

`yubikey-anycast.sh` decides: every 5 s it logs in to the local Radiator,
with a key of its own that works like a YubiKey's. The example below adds anycast to the three
sites of the previous section. `tests/radiator/geo.sh` runs it with an FRR
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
- **The check's user works nowhere else.** Radiator accepts `anycast-*`
  users only from 127.0.0.1, and doesn't write their logins to the
  authentication log.

The check withdraws a server whenever its logins fail, whatever the reason.
While no server can log anyone in, for example while Patroni replaces a
primary that lost power, every server withdraws after 3 checks, and devices
get **no answer** instead of a reject until a server's check passes again.
A network device that falls back to its local accounts when no RADIUS
server answers will do so during that time.

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
| The primary (East1) loses power | Rejected at first; West and East2 withdraw 10 to 17 s after the power loss (3 failed checks), and there is no answer until they advertise again, about 40 s after it. |
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
  3784 (BFD). From the devices to the anycast addresses, UDP 1812.
- **The devices** get the anycast addresses as their RADIUS server. Each
  server still needs a `<Client>` for each device, with the same secret on
  every server.

### Set up anycast on each server

**1. Install FRR** and copy three files from this repository:

```bash
sudo apt install frr
sudo install -m 0755 yubikey-anycast.sh /usr/local/sbin/yubikey-anycast.sh
sudo install -m 0644 yubikey-anycast.service /etc/systemd/system/
sudo install -m 0600 yubikey-anycast.example.conf /etc/radiator/anycast.conf
sudo systemctl daemon-reload
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
older `radiator.conf`. Then set `BindAddress` (commented out in the
example) to 127.0.0.1, the server's own addresses and the anycast
addresses. On west:

```apache
BindAddress     127.0.0.1, 203.0.113.33, ipv6:2001:db8:33::33, 192.0.2.153, ipv6:2001:db8:153::153
```

```bash
sudo systemctl restart radiator
ss -Hlun 'sport = :1812'
```

`ss` lists one socket for each of the five addresses. Without
`BindAddress`, Radiator listens on all addresses, and its replies to
requests sent to an anycast address come from the server's own address.

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
(`sudoedit /etc/radiator/anycast.conf`). Then give the check its key, in the
database, as the admin (with the `PGHOST` and `~/.pgpass` from
[Set up the three servers](#set-up-the-three-servers), step 7), try it, and
start it:

```bash
sudo yubikey-anycast.sh enroll | ./yubikey-db.sh -b pg import --replace -
sudo yubikey-anycast.sh check
sudo systemctl enable --now yubikey-anycast
```

`enroll` makes a key, a PIN and the user `anycast-west`, keeps them in
`/var/lib/yubikey-anycast/key` (mode `0600`), and prints them as one CSV
line for `import`, through the pipe, never on a command line. `check`
prints `ACCEPT in 148 ms` (at West). About 10 s after the start, the
addresses are on `lo`, and the router has the routes:

```text
$ sudo yubikey-anycast.sh status
advertised since 2026-10-13 12:26:43 UTC
last check: ACCEPT in 127 ms, 1 s ago
on lo: 192.0.2.153 2001:db8:153::153
OTPs left: 8386814 (485 days at one check every 5 s)
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

- **See what a server advertises:** `sudo yubikey-anycast.sh status` (it
  exits 0 only while the addresses are on `lo`, for monitoring), and
  `journalctl -u yubikey-anycast`, which logs each change and each new kind
  of check result:

  ```text
  started: anycast-west logs in every 5 s; 192.0.2.153 2001:db8:153::153 on lo after 2 good checks, off after 3 failed; 8388095 OTPs left (485 days)
  check: ACCEPT in 580 ms
  advertising 192.0.2.153 2001:db8:153::153: 2 good checks
  check: NO REPLY: Connection refused
  withdrawing 192.0.2.153 2001:db8:153::153: 3 failed checks
  ```

  (The first login of each of Radiator's processes at West takes about
  0.5 s, while it connects to the primary. Radiator was stopped before the
  fourth line.)

  On a router, `show bgp ipv4 unicast 192.0.2.153/32` lists the servers
  that advertise it.
- **Before maintenance on a server, stop its check:**
  `sudo systemctl stop yubikey-anycast`. Its site's devices move to another
  site at once. Start it when you are done; the server is back after two
  good checks. A reboot does this by itself: the check stops before
  Radiator and FRR do.
- **Replace the check's key when it runs out.** Like a YubiKey's, its OTPs
  have counters that only go up: one key lasts about 485 days at one check
  every 5 s. `status` shows how many OTPs are left, and the log warns when
  fewer than 30 days remain. Stop the check, run the `enroll` and `check`
  lines of step 5 again, and start it. `enroll` keeps the public ID, so
  `import --replace` replaces the old key.
- **Taking a server away for good:**
  `sudo systemctl disable --now yubikey-anycast`, then remove its check's
  user: `./yubikey-db.sh -b pg delete anycast-west`.

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
- **Anycast:** `/var/lib/yubikey-anycast/key` holds a working login, the
  check's PIN and AES key: mode `0600`, root only. Radiator accepts the
  check's users (`anycast-*`) only from 127.0.0.1, because of the first
  `<Handler>` in `radiator.example.conf`; keep it before the one for
  everyone else. `/etc/radiator/anycast.conf` holds the secret of
  `<Client 127.0.0.1>`: mode `0600`. Each router accepts only the two
  anycast routes from its server. If your routers require BGP passwords,
  FRR sets them with `neighbor ADDRESS password` (the test doesn't use
  them).
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
| Radiator logs `Could not connect to SQL database` | Check `DBSource`, `DBAuth`, the network and `pg_hba.conf`. With the configuration from `config`, Radiator tries again after 10 seconds (`FailureBackoffTime`); a configuration without that line waits 600 seconds, so after fixing it, `sudo systemctl restart radiator`. |
| Radiator logs `Could not connect ... session is read-only` | That server is a standby. Normal for the standby when both servers are listed. If every server says so, no server is the primary: promote the standby (see [Fail over](#fail-over)). |
| Radiator logs `Could not connect to any SQL database. Request is ignored` | No listed server accepts writes. Logins are rejected (not ignored) until one does. |
| Radiator logs `counter violation` and `Access ignored ... Database update failed` | The same OTP arrived twice at the same moment (a retransmission, two Radiator servers, or a replay attempt). The first was accepted; the second gets no answer. If it happens without a reason, find where the second request came from. |
| `yubikey-anycast.sh check` prints `ACCEPT ..., but Radiator does not listen on 192.0.2.153 ...` | `BindAddress` doesn't list the anycast addresses, or Radiator logged `Could not bind authentication socket: Cannot assign requested address` at its start (it then runs without them): set `ip_nonlocal_bind` ([Set up anycast on each server](#set-up-anycast-on-each-server), step 2) and restart Radiator. |
| `yubikey-anycast.sh check` prints `NO REPLY within 3 s` | The `SECRET` in `/etc/radiator/anycast.conf` isn't the one of `<Client 127.0.0.1>` (Radiator drops the request without a log line). |
| `yubikey-anycast.sh check` prints `NO REPLY: Connection refused` | Radiator isn't running, or `BindAddress` doesn't list 127.0.0.1. |
| `yubikey-anycast.sh check` prints `REJECT ...: Yubikey secret not found in database` | The check's key isn't in the database (run the `enroll` line of step 5 again), or Radiator can't reach the primary. |
| `yubikey-anycast.sh check` prints `REJECT ...: Replay attack detected` | The counter file is older than the database, for example restored from a backup. The running check skips ahead by itself after a few checks; or make a new key with `enroll`. |
| `yubikey-anycast.sh: error: net.ipv4.ip_nonlocal_bind is not 1` | Step 2 of [Set up anycast on each server](#set-up-anycast-on-each-server). |
| The check says `advertised`, but the router has no route | On the server, `sudo vtysh -c 'show bgp summary'`: a session that isn't `Established` (firewall, AS numbers, addresses), or `(Policy)`, which means a route map is missing. |
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
| `password authentication failed for user "radiator"` | The `DBAuth` line doesn't match the password set with `init-pg --set-password`. |

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
| `add` | `-u USER`, `-P PUBLIC_ID`, `-p PRIVATE_ID`, `-k AES_KEY`, `-w PIN`, `--no-password`, `--inactive`, `--update` or `--replace` | Add one YubiKey; asks for missing values. |
| `import` | `--dry-run`, `--skip-invalid`, `--update` or `--replace`, `--from-export`, `FILE` or `-` | Load a CSV file, or restore an export. |
| `list` | `[USER]` | Show users and YubiKeys, without secrets. |
| `verify` | `-u USER`, `--no-require2factor` | Check a PIN and OTP as Radiator would; save the counters if accepted. |
| `enable`, `disable`, `delete` | `USER [PUBLIC_ID]` | Set `active` to 1 or 0, or delete the user's rows (or one YubiKey). |
| `export` | `-f, --force`, `FILE` or `-` | Write every row and field to CSV (mode `0600`). |
| `config` | | Print the `<AuthBy SQLYUBIKEY>` clause. |

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

### `yubikey-anycast.sh`

```text
yubikey-anycast.sh [-c FILE] COMMAND
```

| Command | What it does |
|---|---|
| `enroll` | Make a new key, PIN and user (`anycast-` and the host name) for the check, keep them in `/var/lib/yubikey-anycast/key`, and print them as CSV for `yubikey-db.sh import --replace -`. Keeps the public ID of an earlier key. Not while the check runs. |
| `check` | Log in once, and check that Radiator listens on the anycast addresses; exits 0 if both work. Not while the check runs. |
| `run` | The check, as `yubikey-anycast.service` runs it. |
| `status` | Whether the addresses are on `lo`, since when, the last check, and the OTPs left. Exits 0 only while they are on `lo`. |
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

It exits with 0 on success, 1 when a check fails (`check`) or the addresses
aren't on `lo` (`status`), and 3 for a problem with the settings, the key or
the system, which the service then doesn't restart on.

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

PostgreSQL roles: `yubikey_admin` owns the database and table; its members
manage users. `radiator` can `SELECT` username, password, active, tokenId,
userId, secret and the counters, and `UPDATE` only accessed and the counters.

In both databases, the trigger `yubikeys_counters_forward` refuses an
`UPDATE` of `counter` or `low` that doesn't move them forward, with the error
`counter violation: ... already used this OTP or a later one`. To reset a
YubiKey's counters on purpose, replace its row (`add --replace`).

### Export format

`export` writes the header
`username,public_id,private_id,aes_key,password,active,created,accessed,counter,low,high`
and one row per YubiKey: AES keys as 32 hex characters, PINs as stored, times
in UTC, and fields with a comma, quote or line break quoted. Only
`import --from-export` reads it.

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

## Testing

`tests/run-tests.sh` runs the scripts through 36 scenarios against throwaway
SQLite and PostgreSQL databases and compares each transcript (commands,
output, exit codes, and the final table) with `tests/expected/`. The two
`anycast` scenarios run `yubikey-anycast.sh` against a stand-in RADIUS
server, which checks each request the way Radiator does, and stand-ins for
`ip` and `ss`. It needs `bash`, `sqlite3`, `perl`, and, for the `verify`
and `anycast` scenarios, `openssl` and `libcrypt-rijndael-perl`; it runs as
a normal user.

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
