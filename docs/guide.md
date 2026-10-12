# YubiKey OTP on Radiator with SQLite or PostgreSQL

A how-to guide for offline YubiKey one-time-password (OTP) logins on
[Radiator](https://radiatorsoftware.com/) RADIUS, with the YubiKeys kept in a
local SQLite database or a shared PostgreSQL database, managed with the scripts
in this repository. It covers a lab you can build in a container, a server
installation, adding accounts, checking credentials, day-to-day maintenance,
and moving from SQLite to PostgreSQL.

Every procedure in this guide was run as written with **Radiator 4.30** on
**Ubuntu 26.04 LTS** with **PostgreSQL 18**, and `tests/radiator/run.sh`
repeats the checks (see [Testing](#testing)).

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
12. [Security](#security)
13. [Troubleshooting](#troubleshooting)
14. [Reference](#reference)
15. [Testing](#testing)
16. [References](#references)
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
   counters.

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
| Radiator server | The Radiator packages, `libauth-yubikey-decrypter-perl`, `libcrypt-rijndael-perl`, and `libdbd-sqlite3-perl` + `sqlite3` (SQLite) or `libdbd-pg-perl` + `postgresql-client` (PostgreSQL) |
| Where you run the scripts (usually the Radiator server) | `bash`, `perl`, `sqlite3` or `postgresql-client`; `libcrypt-rijndael-perl` for `verify` |
| PostgreSQL server (if separate) | `postgresql` |
| Workstation that programs keys | `ykman` |

## Try it in a lab container

A lab shows the whole setup working before you touch a server, and needs no
YubiKey: `tests/make-otp.sh` makes OTPs for test keys. The container is
Ubuntu 26.04 with Radiator, SQLite and PostgreSQL 18.

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

`tests/radiator/run.sh` builds the same image and runs 78 checks of real
Radiator logins in a throwaway container: SQLite with and without
`Require2Factor`, PostgreSQL over the local socket and over TLS, the example
wrapper, and a cutover from SQLite to PostgreSQL while Radiator runs. For each
login it checks Radiator's answer and the reason it logs, and that `verify`
agrees:

```bash
tests/radiator/run.sh ~/radiator-packages
```

It prints one `PASS` or `FAIL` line per check and ends with
`Radiator 4.30-1: 78 passed, 0 failed`. Run it again with each new Radiator
version.

## Install on the servers

### Radiator server

Install Radiator, the Perl modules its YubiKey support needs, and the
database driver you use:

```bash
sudo apt install ./radiator_4.30-1_all.deb ./radiator-radius-utilxs_2.4-4.resolute_amd64.deb \
                 libauth-yubikey-decrypter-perl libcrypt-rijndael-perl
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
`sslrootcert`. You add Radiator's password in the next section.

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
| Radiator logs `Could not connect to SQL database` | Check `DBSource`, `DBAuth`, the network and `pg_hba.conf`. Radiator then stops trying for 600 seconds, so after fixing it, `sudo systemctl restart radiator`. |
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
`PGHOST`, `PGPORT`, `PGUSER`, `PGSSLMODE`, `PGSSLROOTCERT`, `PGSERVICE`
(standard PostgreSQL settings; for a server other than the local socket,
`config` copies `PGHOST`, `PGPORT`, `PGSSLMODE` and `PGSSLROOTCERT` into
Radiator's `DBSource`), `PG_ADMIN_ROLE` (default `yubikey_admin`),
`PG_RADIATOR_ROLE` (default `radiator`), `SQLITE3`, `PSQL`.

| Command | Options | What it does |
|---|---|---|
| `init` | `-o, --owner USER[:GROUP]` | SQLite: create the folder, file and table. PostgreSQL: create the table and grants in an existing database. Safe to re-run. |
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
   and the time.

## Testing

`tests/run-tests.sh` runs the scripts through 33 scenarios against throwaway
SQLite and PostgreSQL databases and compares each transcript (commands,
output, exit codes, and the final table) with `tests/expected/`. It needs
`bash`, `sqlite3`, `perl`, and, for the `verify` scenarios, `openssl` and
`libcrypt-rijndael-perl`; it runs as a normal user.

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

`tests/radiator/run.sh DIR` tests against Radiator itself, in a container
built from the Radiator packages in `DIR` (see
[The automated test](#the-automated-test)).

## References

- [Radiator reference: `<AuthBy SQLYUBIKEY>`](https://files.radiatorsoftware.com/radiator/ref/AuthBySQLYUBIKEY.html)
- [Radiator reference: `AuthSelect` for SQLYUBIKEY](https://files.radiatorsoftware.com/radiator/ref/AuthSelect_AuthBySQLYUBIKEY.html)
- The Radiator distribution's `goodies/yubikey.cfg` and `goodies/yubikey.txt`
- [YubiKey Manager (`ykman`) documentation](https://docs.yubico.com/software/yubikey/tools/ykman/)
- [PostgreSQL 18: SSL support](https://www.postgresql.org/docs/18/ssl-tcp.html) and
  [the pg_hba.conf file](https://www.postgresql.org/docs/18/auth-pg-hba-conf.html)
