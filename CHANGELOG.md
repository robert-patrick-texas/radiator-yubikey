# Changelog

## Unreleased

### Added

- `setup.sh --status` (and the package's `yubikey-turnkey-setup.sh
  --status`, without the folder): checks a turn-key server without
  changing anything (its services, etcd, Patroni, Radiator's listeners,
  the anycast check and its key, partition mode, BGP, the firewall, the
  certificates, the disk, the clock, and whether `setup.sh` has made what
  its folder holds) and sums it up in its first line, `OK`, `WARNING` or
  `CRITICAL`, with the exit status that monitoring tools expect (0, 1, 2;
  3 when it can't check). See the guide's
  [Check a turn-key server](docs/guide.md#check-a-turn-key-server).
- `yubikey-backup.sh`, with `yubikey-backup.service` and
  `yubikey-backup.timer` (installed, not enabled): an encrypted backup of
  a PostgreSQL database every day on each server, from its own
  PostgreSQL (a standby's too), with `pg_dump` and `openssl cms`
  (AES-256-GCM, RSA-OAEP) for a certificate whose private key is kept off
  the servers; the dump is never on disk in clear. It keeps `KEEP` of
  them, 7 by default, in `/var/backups` (`yubikey-db.cms.0`, the newest,
  to `.6`, group `adm`). `check` decrypts one and reads it back whole,
  `decrypt` writes it out, both only when the file is whole and
  unchanged, and on any machine with `openssl` and `pg_restore`.
  `restore`, on the primary, says what it would undo (YubiKeys, service
  accounts and groups added, deleted or changed since), asks, and
  replaces every table in one transaction, keeping the counters that are
  ahead and the anycast checks' keys; it waits at most 10 s for a lock.
  `status` exits 0 while the newest is less than 26 hours old. See the
  guide's [Automatic backups](docs/guide.md#automatic-backups).
- Turn-key setup: `[backup]` in `site.toml` (`certificate`, `keep`; in
  `site.example.toml`): `setup.sh` installs the certificate and the
  settings, starts the timer and makes the first backup; `--status` warns
  when the newest backup is more than 26 hours old, the last one failed,
  or the timer is off; `--reset` leaves the backups. `yubikey-turnkey`
  checks the certificate (RSA, 3072 bits or more, no private key in the
  file), and writes `secrets.toml` encrypted for it
  (`out/secrets.toml.cms`, and on each server
  `/var/backups/yubikey-turnkey-secrets.toml.cms`), made again only when
  `secrets.toml` or the certificate changes. Without `[backup]` it says
  that the servers make no backups. See the guide's
  [Turn-key backups](docs/guide.md#turn-key-backups).
- Turn-key: a lost server is set up again with the same name and
  addresses, while the other two run: its folder and `setup.sh`, on a new
  server, or after `setup.sh --reset NAME` on it alone. `setup.sh` removes
  the server's etcd member from before and adds it again (as a learner
  until it has caught up), and its etcd joins the cluster that runs;
  Patroni copies the database, on the first server too, which is then a
  standby (`--status` says to move the primary back); the database is
  left as it is; and the anycast check takes its key (renewed since,
  perhaps) and counter from the database. While two
  servers' etcd is down, it stops at etcd, before starting it, and says
  why; when all three's was, it joins once the others run again. The
  runbook says what to do when a server is lost. See the guide's
  [Rebuild a turn-key server](docs/guide.md#rebuild-a-turn-key-server).
- Turn-key: `setup.sh --alone`, for when two servers are lost for good: on
  the third, it makes its etcd a cluster of one, with its data, and its
  PostgreSQL the primary (which Patroni, in quorum mode, doesn't do by
  itself), after checking that the other two answer on none of etcd's,
  PostgreSQL's and Patroni's ports, and asking (`--yes`: it doesn't). Then
  `setup.sh` on the other two, set up again, joins them to it, at the same
  time too, and the third's partition mode moves the counters of the
  logins in between into the database. The runbook has a "Two servers
  lost" section. See the guide's
  [Two servers lost](docs/guide.md#two-servers-lost).
- Turn-key: a server replaced, with new addresses or a new name (when a
  site moves, say): after `site.toml` and `yubikey-turnkey`, `setup.sh`
  with the new folders on the two that stay, then on the new server, which
  removes the old server's etcd member before adding its own (and stops
  while that one still answers). `yubikey-turnkey` says when a server has
  new addresses (a new certificate), or is gone from `site.toml` (its
  anycast key and certificate with it). The runbook has an "A server
  replaced" section. See the guide's
  [Replace a turn-key server](docs/guide.md#replace-a-turn-key-server).

### Changed

- `yubikey-partition.sh status` says why the copy isn't updated, while it
  isn't (`copy not updated: ...`).
- The turn-key runbook checks each server with `setup.sh --status`, and
  says where the backups are.
- `yubikey-turnkey` says `removed out/FILE` for a file of its own it
  removed from `out/`.
- Turn-key: every server's folder has `db/` and the roles' SCRAM
  verifiers, and whichever server is the primary applies them when its
  `setup.sh` runs (it was the first server only): the anycast checks of
  the three servers, each once, and those of servers no longer in
  `site.toml` removed. A first server that isn't the primary waits for its
  anycast check instead of stopping.
- Turn-key: on a server whose etcd already ran, `setup.sh` needs only
  etcd's quorum (it waited for all three), and doesn't restart etcd when
  only its `ETCD_INITIAL_*` settings changed.
- `setup.sh --reset NAME` says what to run next: `setup.sh` on this server
  alone joins the other two again; after `--reset` on all three, on all
  three.

### Tests

- `tests/radiator/turnkey.sh` (299 checks): `setup.sh --status` on
  the three servers, from the package without the folder, and not as root;
  and what it says with etcd stopped on one server, a router down, the
  primary moved, the anycast addresses withdrawn, a folder copied but not
  set up, a backup 30 hours old and the backups' timer stopped. The
  backups: the first, made by `setup.sh`; more on a standby, of which it
  keeps `keep`; one checked and decrypted on the admins' machine with a
  key pair made as the guide says; a restore on the primary after a login,
  a deleted YubiKey, a group change and a renewed anycast key (what it
  undoes, the counters and the checks' keys it keeps, logins right after),
  refused on a standby; servers rebuilt with the same names and addresses
  (West, whose check renewed its key, and East1, lost while it was the
  primary, on new containers, with logins going on meanwhile, etcd's
  member added again, the check's key and counter from the database, and
  the primary moved back; East2 in place after `--reset`); `setup.sh`
  stopping at etcd while East2's is stopped, and joining when all three's
  was; two servers lost (East1 and East2: logins through West from its
  copy, `setup.sh --alone` on West, refused while they run, without a
  terminal and when not answered yes, the two set up again at the same time, the OTP used on West
  alone refused after, the primary moved back); after `--reset` on all
  three, the last backup restored into the new cluster; and servers
  replaced: West moved to new addresses, after `--reset` on it (its
  `--check` warning before the two that stay knew it), and East1, lost
  while the primary, replaced by a server of a new name and addresses,
  which then became the primary.
- `tests/radiator/geo.sh` (212 checks): the guide's steps for automatic
  backups on the three sites, a backup checked and decrypted on the
  client, and restored on the primary at its prompt after a login (the OTP
  stays used; logins and anycast go on).
- `tests/radiator/package.sh`: the backups' units are installed, neither
  enabled nor started, and pass `systemd-analyze verify`.
- `tests/run-tests.sh` (48 scenarios): `turnkey` runs `setup.sh --status`
  as a normal user and with another option, `--alone` as a normal user and
  with another option, and `--yes` alone, and checks `secrets.toml.cms`
  (it decrypts to `secrets.toml`, is made again only when it or the
  certificate changes, and goes with `[backup]`), and `db/` in every
  folder; `turnkey_errors` the checks of `[backup]`; `turnkey_secrets` a
  server with new addresses and a server renamed (what the tool says, and
  the keys and certificate that go and come); `pg_partition` shows the copy that isn't updated;
  new: `backup` (the settings, `status`, and `decrypt` of whole, changed
  and cut files, with right and wrong keys and passphrases) and
  `pg_backup` (`run` and how many it keeps, `check`, and `restore`: its
  list of changes, the counters and anycast keys it keeps, Radiator's
  rights after it, a changed file, a wrong passphrase, a dump cut short, a
  lock held for long, and a database without the tables). Their test key
  pair is in `tests/turnkey/`.

## 1.11.0 - 2026-10-16

The turn-key setup: three sites, with partition mode, anycast, groups and
TACACS+, set up from one input file with `yubikey-turnkey` (see the
guide's new section, [Turn-key setup](docs/guide.md#turn-key-setup)).
Nothing changes for an installation that doesn't use it, and there is
nothing to do after upgrading from 1.10.0. The package now depends on
`python3`.

### Added

- `yubikey-turnkey`: the setup of three sites (with partition mode,
  anycast, groups and TACACS+) from one input file, `site.toml` (see
  `site.example.toml`). It makes every password, key and certificate once,
  in `secrets.toml` (mode `0600`), and writes a folder for each server with
  a `setup.sh` that installs and configures everything on it: the
  packages, `/etc/hosts`, etcd, PostgreSQL under Patroni, the database
  with the anycast checks' keys and service accounts and the groups to
  start with, Radiator with the devices, partition mode, FRR and the
  anycast check, and an iptables firewall. The three servers run it at the
  same time, and it can be run again: it changes only what differs. It
  also writes a runbook, a sheet for the routers and one for the devices
  (with their secrets and keys), and the admins' PostgreSQL settings. The
  guide has a new section, [Turn-key setup](docs/guide.md#turn-key-setup).
- The package has `yubikey-turnkey`, `yubikey-turnkey-setup.sh` (which it
  copies as each server's `setup.sh`) and `site.example.toml`, and depends
  on `python3`.

### Tests

- `tests/run-tests.sh`: scenarios `turnkey` (the example input, with fixed
  secrets: everything it writes), `turnkey_errors` (the input checks) and
  `turnkey_secrets` (the secrets it makes, and changed by hand); 46 scenarios
  in all.
- `tests/radiator/turnkey.sh` (`run.sh DIR turnkey`, 96 checks): the
  folders that `yubikey-turnkey` makes, run on three fresh Ubuntu 26.04
  servers at once, with two routers at one site and a device behind them:
  logins at the anycast addresses over RADIUS and TACACS+, IPv4 and IPv6,
  refused for a group without access; a server withdrawn from both of its
  routers when only its TACACS+ login fails; the firewall; `setup.sh` run
  again, a reboot, a new device, new certificates, and `--reset`.
- `tests/radiator/tacacs.pl` connects over IPv6 without
  `libio-socket-inet6-perl`.

## 1.10.0 - 2026-10-16

TACACS+, service accounts and groups, and an anycast check that also logs
in over TACACS+ and renews its own key. Nothing changes for an installation
that doesn't use them. To use them, run `yubikey-db.sh init` (or `-b pg
init`), which adds their tables, and follow the guide's new section,
[Groups and TACACS+](docs/guide.md#groups-and-tacacs). A clause written
again with `config` for a remote PostgreSQL has three `DBAuth` lines, one
for each clause: put Radiator's password on each. With PostgreSQL, `init`
also adds the function with which the anycast check renews its key; until
then, the check logs that it can't, and works as before.

### Added

- Service accounts (`svc.NAME`), which log in with a password instead of a
  YubiKey: `yubikey-db.sh service add|password|list|enable|disable|delete|label`.
  Passwords are at least 12 characters, asked for twice, read from standard
  input, or generated (`--generate`), and stored as `{crypt}` SHA-512
  hashes.
- Groups: `group add|delete|list|label`, `member add|delete`,
  `access set|delete|list|check` and `rule add|delete|list`. A group may
  log in to a device group (the `Identifier` of the devices' `<Client>`
  clauses, or `*`) at a TACACS+ privilege level, with RADIUS reply
  attributes and TACACS+ command rules. An account gets the most
  privileged of its groups allowed on the device, and only while it has an
  active YubiKey or is an active service account. `access check` shows
  what Radiator finds for an account on a device group.
- Tables `service_accounts`, `user_groups`, `group_members`,
  `group_access` and `group_rules`, and the view `access_replies`, in both
  databases. `init` adds them to an existing database and prints
  `Added the service-account and group tables`. In PostgreSQL, Radiator's
  role may read only the view and the service accounts' names, password
  hashes and `active`.
- `config` also prints the clauses `ServiceAccounts` and `GroupAccess` (for
  PostgreSQL, reading from any server that answers, the primary or a
  standby). Both have `NoDefault`, so Radiator never falls back to an
  account called `DEFAULT`.
- `radiator-groups.example.conf`: RADIUS and TACACS+ (port 49) through the
  same Handlers, the YubiKey or password check followed by the group check,
  devices in `/etc/radiator/clients.d`, TACACS+ accounting to a file. Every
  TACACS+ authorization asks the groups again (`AllowAuthorizeOnly`,
  `AuthorizationTimeout 0`), so a change, or a disabled account, applies to
  sessions already open within 2 seconds, whichever of Radiator's
  processes answers. It works around Radiator 4.30 answering a refused
  TACACS+ authorization with an authentication packet, which devices take
  for an error.
- `dictionary.yubikey`, with the attribute `YubiKey-Via` that marks TACACS+
  requests; a RADIUS client can't send it.
- Partition mode: the copy also holds the service accounts and groups, and
  a copy made by an older version gets their tables at the next sync.
  `setup` now runs `yubikey-db.sh init` on an existing copy too.
- `config`: the YubiKey clause has `NoDefault`, so Radiator never falls
  back to a user called `DEFAULT`. Radiator 4.30's YubiKey clauses already
  don't, by default (and look up the login's own username in any case), so
  nothing changes; the line keeps it so. `e2e.sh` checks that a YubiKey
  stored for `DEFAULT` logs in no one else, with and without the line.
- `yubikey-db-migrate.sh` copies only the YubiKeys, as before, and warns
  when the SQLite database has service accounts or groups, which it doesn't
  copy.
- The anycast check can log in over TACACS+ too. With `TACACS_KEY` (the
  `TACACSPLUSKey` of `<Client 127.0.0.1>`) in `/etc/radiator/anycast.conf`,
  each check of `yubikey-anycast.sh` also logs in over TACACS+, at the same
  time as the RADIUS login, as the service account `svc.anycast-HOSTNAME`;
  asks for the session's authorization, as a device does; and checks that
  Radiator listens on TCP port 49 on the anycast addresses. The addresses
  come off `lo` when either login fails. `yubikey-anycast.sh enroll-tacacs`
  makes the account's password and prints it for `yubikey-db.sh service
  add`. `radiator-groups.example.conf` accepts these accounts only from
  127.0.0.1 and doesn't log their logins; they need a group with access to
  device group `localhost`. Without `TACACS_KEY`, the check works as before.
- The anycast check renews its key by itself: every 365 days
  (`RENEW_DAYS`), or sooner when only 30 days of OTPs are left, after a
  good check, it gives the key a new private ID and AES key, in the
  database and in its key file, and its counters start again. It writes
  with Radiator's own login (from `yubikey-cluster.conf`, or
  `yubikey.conf`) through the new PostgreSQL function `anycast_renew`,
  which Radiator's role may run and which changes only the keys of
  `anycast-*` users. A renewal whose answer was lost is finished with the
  same key. Not in partition mode, and not with SQLite. `status` shows the
  next renewal; `yubikey-anycast.sh renew` renews the key at once. The key
  file has a new line, `made=`; a key file from before has the date it was
  written.

### Tests

- `tests/run-tests.sh`: scenarios `groups` and `pg_groups` (42 in all),
  which also run Radiator's `GroupAccess` query (on PostgreSQL as
  Radiator's role); `pg_partition` checks the copied groups.
- `tests/radiator/groups.sh` (`run.sh DIR groups`): Radiator with
  `radiator-groups.example.conf`, logins over TACACS+ and RADIUS on SQLite
  and PostgreSQL, with `tests/radiator/tacacs.pl`, a small TACACS+ client
  on Radiator's own modules, and the anycast check over both.
- The `anycast` and `anycast_run` scenarios also run the check against a
  stand-in TACACS+ server: its answers, a wrong key, no answer, and the
  addresses withdrawn when only the TACACS+ login fails.
- `tests/run-tests.sh`: scenario `pg_anycast` (43 in all), the key renewed
  in PostgreSQL: by hand and by the running check, hex and base64 keys, a
  lost answer, no function, partition mode, and what Radiator's role may
  do with the function.
- `e2e.sh`: the check renews its key over TLS with Radiator's login, then
  logs in with the new key, and Radiator refuses the old one. `geo.sh`:
  West's check renews its key under systemd, with partition mode set up,
  and West's copy gets it.

## 1.9.0 - 2026-10-15

A planned switchover no longer leaves a login unanswered now and then. After
upgrading, run `yubikey-db.sh -b pg init` (once, against the primary), and
write Radiator's clause again with `yubikey-db.sh -b pg config` on each
Radiator server, then restart Radiator. Either can come first; until both
are done, Radiator works as before.

### Fixed

- In a planned switchover, or a clean restart of the primary, a login whose
  counters were waiting for the standby when the old primary stopped got no
  answer. PostgreSQL had saved them (`canceling the wait for synchronous
  replication ... The transaction has already committed locally`), but
  Radiator only saw its connection drop, saved them again on the new
  primary, and the trigger refused that as a replay (`counter violation`,
  then `Database update failed`). On three sites, with four logins at a
  time at each site, 6 of 24 switchovers left 1 to 3 logins unanswered (10
  of 9,180 logins), which made `geo.sh` fail now and then since 1.7.0. The
  same login may now save the same counters again; with this version, 26
  more switchovers left none unanswered.

### Added

- PostgreSQL: a `login_id` column, the ID of the Radiator login that last
  saved the counters, kept by the trigger. Radiator's role can neither read
  nor write it. `init` adds it to an existing table and prints
  `Added the login_id column to the yubikeys table`; the other commands
  work with or without it.

### Changed

- `config` for PostgreSQL: `YubiKeyConnect` gives each login a random ID (16
  bytes from `/dev/urandom`), and `UpdateQuery` names the login with
  `set_config('yubikey.login_id', ID, true)`, a condition that is always
  true, for that save only. It also works with a table made before this
  version, as before.
- The trigger `yubikeys_counters_forward` (PostgreSQL) runs on every save of
  the counters. It still refuses counters that don't move forward, except
  the same counters saved again by the login that the save names, and it
  keeps that login's ID in `login_id` (empty after a save that names none,
  from the scripts or from a clause written before this version). The same
  OTP sent twice at the same moment is still refused the second time: the
  two logins have different IDs.

### Tests

- `e2e.sh` loses the answer to a save: every commit waits for a standby that
  doesn't exist, and Radiator's session is ended once its save waits, as a
  primary's fast shutdown ends it. With the `UpdateQuery` of 1.8.1 the
  login gets no answer, though the save was committed; with this version's
  it is accepted, and the same OTP is then a replay.
- `pg_radiator` runs the `UpdateQuery` from `config` as Radiator's role: the
  same counters saved again by the same login pass; by another login, by a
  save that names none, and older counters by the same login are refused;
  Radiator's role can't read or write `login_id`; a table made by 1.8.1
  (without the column, with the old trigger) works with the new clause, and
  `init` adds the column.

## 1.8.1 - 2026-10-15

The scripts are the same as in 1.8.0; this release adds a test with real
Radiator of a user with two YubiKeys. Nothing to do after upgrading from
1.8.0.

### Tests

- `e2e.sh` logs in, on SQLite and PostgreSQL, as a user with two YubiKeys:
  each is found by its public ID, with its own counters (the second's lower
  counter is accepted), its own PIN (the other's is refused) and its own
  `active`; another user's YubiKey is refused, and `verify` shows the label
  of the YubiKey that typed the OTP; 125 checks.

## 1.8.0 - 2026-10-15

Each YubiKey can have a label, such as `primary, slot 1` or `spare, slot 2`,
to tell a user's YubiKeys apart. After upgrading, run `yubikey-db.sh init`
(with `-b pg` for PostgreSQL, once, against the primary) to add the label
column; until then the other commands ask for it, and Radiator keeps
working either way.

### Added

- A label for each YubiKey, such as `primary, slot 1` or `spare, slot 2`, to
  tell a user's YubiKeys apart: a new `label` column (UTF-8 text, up to 255
  characters, no control characters; empty for none). Radiator never reads
  it, and Radiator's PostgreSQL role can't.
- `label USER PUBLIC_ID LABEL` sets the label of one of a user's YubiKeys;
  `''` removes it.
- `add -l LABEL`. On a terminal, `add` without `-l` asks for a label (Enter
  for none).
- `import` takes the label as an optional 7th CSV field, after `active`.
  Files with 4 to 6 fields load as before.
- `list` shows each YubiKey's label, and `verify` shows it on its first line.
- `export` writes the label as a 12th column, and `import --from-export`
  restores it. Exports made before this version (11 columns) still restore.
- `yubikey-db-migrate.sh` copies the labels, from a SQLite database with or
  without the label column, and includes them in its row-by-row check;
  `--mode sync` lists a row whose label differs, without changing it.
- `yubikey-db-user.example.sh` has `cred_label`.

### Changed

- With `--update` or `--replace` (in `add`, `import` and
  `import --from-export`), a YubiKey given no label keeps the label it has,
  even when its private ID or AES key changed. A label that is given
  replaces it.
- `init` adds the `label` column to a table made by an older version, and
  says so. Until then, the other commands stop with a message to run
  `init`; Radiator keeps working either way. With two database servers or
  three sites, run it once, against the primary.
- `yubikey-db-migrate.sh` refuses a PostgreSQL table without the `label`
  column, with a message to run `yubikey-db.sh -b pg init` first.
- Your own `INSERT INTO yubikeys VALUES (...)` statements that don't name
  the columns, like those of the old example commands, fail once the table
  has the `label` column: name the columns, or use `add` or `import`.
- The version is in one file, `VERSION`, which each script reads from next
  to it (`-V` shows it; `unknown` without the file). The package's scripts,
  and the `install.sh` attached to a release, have it written in, so that
  each also runs on its own.
- The README's and the guide's download commands take the latest release
  instead of naming a version.

### Tests

- New scenarios `labels` and `pg_labels`: labels set by `add`, `import` and
  `label`, invalid labels, kept and replaced by `--update` and `--replace`,
  exported and restored (also from an export made before this version),
  hidden from Radiator's role, and added by `init` to a database made by
  1.7.0. `migrate_new` migrates a 1.7.0 SQLite database, `migrate_invalid`
  rejects invalid labels, and `migrate_errors` refuses a 1.7.0 PostgreSQL
  table. The table dumps in every scenario show the label.
- `e2e.sh` logs in with a labeled YubiKey on both databases.
- The transcripts show the scripts' version as `<VERSION>`, so a new version
  changes none. `package.sh` checks that the package's version is the one
  in `VERSION`, and that the `install.sh` built with it has it written in.

## 1.7.0 - 2026-10-14

Planned switchovers and clean restarts of the primary no longer reject
logins: while no server accepts writes but every server answers, Radiator
holds each login until the new primary is ready, for up to 5 s. After a
database failure, Radiator tries again after 2 s instead of 10 s.

### Added

- `config` for PostgreSQL adds two hooks to Radiator's clause
  (`ConnectionHook` and `NoConnectionsHook`). While no server accepts
  writes but every listed server answers, as during a planned switchover or
  a clean restart of the primary, Radiator holds each login and tries again
  every 0.5 s, for up to 5 s, instead of rejecting it; when a server doesn't
  answer at all, it backs off as before. For 10 s after each new
  connection, a query may take 6 s instead of 2: a primary just promoted
  saves a change only once a standby streams from it (1.5 to 3 s in the
  test), and a counter update cut short at 2 s was saved anyway, so
  Radiator's second try failed as a replay and the login got no answer. On
  three sites, with four logins at a time at each site, a planned
  switchover now rejects no login and leaves none unanswered; the slowest
  login at each site took 3.5 to 5.5 s. Radiator builds a login's query before it runs it, and
  needs a connection to build it, so `config` also writes a clause
  `YubiKeyConnect` that connects first (holding the login the same way),
  and makes `YubiKeyLocal`, the name the Handlers use, a group of
  `YubiKeyConnect` and the YubiKey clause, now `YubiKeySQL`. Existing
  configurations are not changed: write `config` again and restart
  Radiator.

### Changed

- `config` for PostgreSQL writes `FailureBackoffTime 2` instead of 10. Each
  of Radiator's processes that finds no server accepting writes rejects
  logins without trying for that long, so a planned switchover on three
  sites rejected logins for about 10 s, though the new primary was ready
  2 to 3 s after the old one began to hand over; with 2 s, and without the
  hooks above, for 2 to 5 s. The guide's "about 5 s" was measured with one
  login a second, which missed the processes still waiting. In return,
  while there is no primary, more rejects wait for servers that don't
  answer: with the primary powered off, about 16% of rejects took about 3 s
  (5% before); at a site cut off from the other two, about 14% took about
  4 s (3% before).

### Tests

- `geo.sh` switches the primary over twice while four users at each site log
  in at the same time, and checks that every login is accepted, within 8 s,
  and that none of their OTPs is a replay.
- `ha.sh` checks that Radiator compiles the hooks, that a login is held
  until the standby is promoted and then accepted, and that with no
  primary for longer it is held for 5 s, then rejected.

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
