# Changelog

## 1.0.1 - 2026-10-06

- Added `-V` / `--version` to `yubikey-db.sh`.
- Fixed the `ykman` example in the script's header comment to use slot 2,
  matching the README and HTML guide (slot 1's factory setting can't be restored).
- README and HTML guide updates made since the 1.0 package was built.
- Added version numbers to the README and HTML guide.

## 1.0 - 2026-10-01

- First release: `init`, `add`, `import`, `list`, `enable`, `disable`,
  `delete`, and `config` commands for the SQLite backend.
