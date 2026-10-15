#!/usr/bin/env bash
#
# install.sh - Install the radiator-yubikey package on a Radiator server, with
#              the packages that it and Radiator's YubiKey support need.
#
# VERSION
#   1.7.0
#
# WHAT IT DOES
#   1. Looks for Radiator. It comes from Radiator Software, as packages or as
#      source, and is not a dependency of the package, so that either works.
#      It counts as installed when one of these is found:
#        - Radiator Software's radiator (or radiator-locked) package
#        - a radiusd from their source, with Radiator's Perl modules: in
#          /opt/radiator/radiator (where their radiator.service runs it), on
#          the PATH (after 'make install', usually /usr/local/bin), or the
#          one given with --radiusd
#      When it finds neither, it says how to install Radiator and asks
#      whether to go on without it. With no terminal to ask on, it stops,
#      unless --yes.
#   2. Installs with apt-get the Perl modules that Radiator's <AuthBy
#      SQLYUBIKEY> and radiator.example.conf need, the SQLite and PostgreSQL
#      drivers and command-line tools, and the package. A package of the
#      version that is installed already is left as it is.
#   3. Checks that Radiator's Perl loads Radiator's SQLYUBIKEY module and
#      the modules it needs, and points out what is left to set up.
#
# USAGE
#   sudo ./install.sh [OPTIONS] [PACKAGE.deb]
#   PACKAGE.deb defaults to the newest radiator-yubikey_*_all.deb next to
#   install.sh. Without one (install.sh in /opt/radiator-yubikey, or in a git
#   clone), it installs the other packages only.
#
# OPTIONS
#   -y, --yes        Go on without asking when Radiator is not found
#   -n, --check      Change nothing: show what is installed and what is
#                    missing (needs no root)
#   --radiusd FILE   Radiator's radiusd, when it is somewhere else
#
# EXIT STATUS
#   0 done (--check: nothing is missing or left to do); 1 an error (--check:
#   something is missing or left to do); 2 a usage error; 3 stopped, because
#   Radiator is not installed.
#
# ENVIRONMENT (for tests)
#   APT_GET, DPKG_QUERY, GETENT  the commands to use (with APT_GET set, it
#                                needs no root)
#   APT_PERL                     the Perl that apt-get installs modules for,
#                                instead of /usr/bin/perl
#   RADIUSD_PATHS                where to look for radiusd, instead of
#                                /opt/radiator/radiator/radiusd and the PATH
#   SYSROOT                      look for the other files (systemd units,
#                                /opt/radiator-yubikey) under this directory

set -uo pipefail
shopt -s nullglob

PROG=${0##*/}
VERSION=1.7.0
HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NEED_ROOT=1; [[ -n ${APT_GET:-} ]] && NEED_ROOT=0
APT_GET=${APT_GET:-apt-get}
DPKG_QUERY=${DPKG_QUERY:-dpkg-query}
GETENT=${GETENT:-getent}
APT_PERL=${APT_PERL:-/usr/bin/perl}
SYSROOT=${SYSROOT:-}
DEST=/opt/radiator-yubikey   # where the package puts the scripts

# What apt-get installs, and the Perl modules that Radiator's Perl must load,
# as MODULE=where it comes from.
PACKAGES=(libauth-yubikey-decrypter-perl libcrypt-rijndael-perl libcache-fastmmap-perl
          libdbd-sqlite3-perl sqlite3 libdbd-pg-perl postgresql-client)
MODULES=(Radius::AuthSQLYUBIKEY=Radiator
         Auth::Yubikey_Decrypter=libauth-yubikey-decrypter-perl
         Crypt::Rijndael=libcrypt-rijndael-perl
         Cache::FastMmap=libcache-fastmmap-perl
         DBD::SQLite=libdbd-sqlite3-perl
         DBD::Pg=libdbd-pg-perl)

YES=0 CHECK=0 RADIUSD='' DEB=''
MISSING=0      # --check: something is missing
NOTES=()       # what is left to set up, shown at the end
# What find_radiator found
RAD_PKG='' RAD_PKG_VERSION='' RAD_UTILXS='' RAD_RADIUSD='' RAD_PERL='' RAD_LIB='' RAD_VERSION=''

die()  { printf '%s: error: %s\n' "$PROG" "$*" >&2; exit 1; }
usage_error() { printf '%s: %s (see %s --help)\n' "$PROG" "$*" "$PROG" >&2; exit 2; }

# note TEXT [COMMAND...]: something left to set up, shown at the end: TEXT
# wrapped, each COMMAND on a line of its own.
note() { local IFS=$'\n'; NOTES+=("$*"); }

print_notes() {
    local n
    [[ ${#NOTES[@]} -gt 0 ]] || return 0
    printf '\nTo do:\n'
    for n in "${NOTES[@]}"; do
        printf '%s\n' "${n%%$'\n'*}" | fold -s -w 74 | sed 's/ *$//; 1s/^/  - /; 2,$s/^/    /'
        if [[ $n == *$'\n'* ]]; then printf '%s\n' "${n#*$'\n'}" | sed 's/^/      /'; fi
    done
}

usage() {
    cat <<EOF
Usage: sudo ./$PROG [OPTIONS] [PACKAGE.deb]

Checks that Radiator is installed, then installs PACKAGE.deb with the
packages that it and Radiator's YubiKey support need. PACKAGE.deb defaults
to the newest radiator-yubikey_*_all.deb next to $PROG; without
one, it installs the other packages only.

Options:
  -y, --yes        Go on without asking when Radiator is not found
  -n, --check      Change nothing: show what is installed and what is missing
  --radiusd FILE   Radiator's radiusd, when it is somewhere else
  -h, --help       Show this help
  -V, --version    Show the version
EOF
}

# The version of installed package NAME; fails when it is not installed.
installed_version() {
    local status version
    # shellcheck disable=SC2016  # dpkg-query's ${...} fields
    read -r status version < <("$DPKG_QUERY" -W -f='${db:Status-Status} ${Version}\n' "$1" 2>/dev/null) \
        && [[ $status == installed ]] && printf '%s\n' "$version"
}

# The Perl that runs FILE, from its #! line.
script_perl() {
    local line interp arg
    IFS= read -r line <"$1" || true
    if [[ $line != '#!'* ]]; then echo perl; return; fi
    read -r interp arg _ <<<"${line#'#!'}"
    if [[ ${interp##*/} == env ]]; then interp=$arg; fi
    printf '%s\n' "$interp"
}

# Look for Radiator: its package, and a radiusd with Radiator's Perl modules
# (next to it, as in /opt/radiator/radiator, or in its Perl's @INC, after
# 'make install'). Sets the RAD_* variables; fails when no radiusd is found.
find_radiator() {
    local pkg version f perl lib
    local -a candidates=()
    for pkg in radiator radiator-locked; do
        if version=$(installed_version "$pkg"); then RAD_PKG=$pkg RAD_PKG_VERSION=$version; break; fi
    done
    RAD_UTILXS=$(installed_version radiator-radius-utilxs) || RAD_UTILXS=''
    if [[ -n $RADIUSD ]]; then
        candidates=("$RADIUSD")
    elif [[ -n ${RADIUSD_PATHS+set} ]]; then
        read -ra candidates <<<"$RADIUSD_PATHS"
    else
        candidates=(/opt/radiator/radiator/radiusd)
        if f=$(command -v radiusd); then candidates+=("$f"); fi
    fi
    for f in "${candidates[@]}"; do
        [[ -f $f ]] || continue
        perl=$(script_perl "$f")
        if [[ -f $(dirname -- "$f")/Radius/Util.pm ]]; then
            lib=$(dirname -- "$f")
        else
            # shellcheck disable=SC2016  # Perl's @INC and $_
            lib=$("$perl" -e 'for (@INC) { if (-f "$_/Radius/Util.pm") { print "$_\n"; last } }' 2>/dev/null)
        fi
        [[ -n $lib ]] || continue
        RAD_RADIUSD=$f RAD_PERL=$perl RAD_LIB=$lib
        RAD_VERSION=$(sed -n "s/^\$main::VERSION *= *'\([^']*\)'.*/\1/p" "$lib/Radius/Util.pm")
        return 0
    done
    if [[ -n $RADIUSD ]]; then
        die "$RADIUSD is not Radiator's radiusd: Radius/Util.pm is neither next to it nor in its Perl's @INC"
    fi
    return 1
}

# Show what was found of Radiator; with none, say how to install it, and ask
# whether to go on (or stop).
report_radiator() {
    local answer utilxs=''
    if [[ -n $RAD_UTILXS ]]; then utilxs=" (with radiator-radius-utilxs $RAD_UTILXS)"; fi
    if [[ -n $RAD_RADIUSD ]]; then
        if [[ -n $RAD_PKG ]]; then
            printf 'Radiator:  %s, Radiator Software'\''s package %s%s: %s\n' "$RAD_PKG_VERSION" "$RAD_PKG" "$utilxs" "$RAD_RADIUSD"
        else
            printf 'Radiator:  %s, from source: %s\n' "${RAD_VERSION:-version unknown}" "$RAD_RADIUSD"
        fi
        return 0
    fi
    if [[ -n $RAD_PKG ]]; then
        printf 'Radiator:  %s, Radiator Software'\''s package %s%s, but its radiusd was not found\n' "$RAD_PKG_VERSION" "$RAD_PKG" "$utilxs"
        MISSING=1
        return 0
    fi
    MISSING=1
    cat <<EOF
Radiator:  not found
  Neither Radiator Software's radiator package nor a radiusd from their
  source is installed. Install Radiator first, in one of these ways:
    - their packages, for example:
        sudo apt install ./radiator_4.30-1_all.deb ./radiator-radius-utilxs_2.4-4.resolute_amd64.deb
    - their source: unpacked in /opt/radiator/radiator, or installed with
        perl Makefile.PL && make && sudo make install
  If it is installed somewhere else, give its radiusd with --radiusd FILE.
  Without Radiator, the scripts can still manage a database (on another
  server than Radiator's, for example).
EOF
    if [[ $CHECK == 1 ]]; then
        return 0
    elif [[ $YES == 1 ]]; then
        echo "Going on without Radiator (--yes)."
    elif [[ -t 0 ]]; then
        read -r -p "Go on without Radiator? [y/N] " answer || answer=
        if [[ ! $answer =~ ^[Yy] ]]; then
            echo "Stopped: install Radiator, then run $PROG again."
            exit 3
        fi
    else
        echo "Stopped: install Radiator and run $PROG again, or run it with --yes"
        echo "to go on without it."
        exit 3
    fi
}

# Check that Radiator's Perl loads each of MODULES.
check_modules() {
    local m module from status perl
    local -a missing=()
    perl=$(command -v -- "$RAD_PERL") || perl=$RAD_PERL
    printf '\nRadiator'\''s Perl (%s) loads:\n' "$perl"
    for m in "${MODULES[@]}"; do
        module=${m%%=*} from=${m#*=}
        if "$RAD_PERL" -I"$RAD_LIB" -M"$module" -e 1 >/dev/null 2>&1; then
            status=ok
        else
            status=missing MISSING=1
            missing+=("$module")
        fi
        printf '  %-8s %-24s (%s)\n' "$status" "$module" "$from"
    done
    if [[ $perl != "$APT_PERL" && ${#missing[@]} -gt 0 ]]; then
        note "Radiator runs with $perl, but apt-get installs Perl modules for $APT_PERL: install the missing ones for $perl too (with cpanm, for example)."
    elif [[ $CHECK == 0 && ${#missing[@]} -gt 0 ]]; then
        note "Radiator's Perl still can't load ${missing[*]}, which its YubiKey support needs."
    fi
}

# Notes for Radiator from source: the user and the systemd unit that
# Radiator Software's package would have made.
check_source_install() {
    local d found=0
    if ! "$GETENT" passwd radiator >/dev/null; then
        note "There is no user radiator. Radiator Software's radiator.service, and the guide, run Radiator as radiator:" \
             "sudo groupadd -r radiator" \
             "sudo useradd -r -g radiator -d /var/lib/radiator -s /usr/sbin/nologin radiator"
    fi
    for d in etc/systemd/system usr/lib/systemd/system lib/systemd/system run/systemd/system; do
        if [[ -e $SYSROOT/$d/radiator.service ]]; then found=1; fi
    done
    if [[ $found == 0 ]]; then
        note "There is no radiator.service. The guide starts Radiator with 'systemctl start radiator', and partition mode restarts it that way: copy goodies/radiator.service from Radiator's source to /etc/systemd/system/, with its paths changed to those of your radiusd."
    fi
}

# Notes for units and scripts installed by hand, as earlier versions of the
# guide said, which the package's units don't use.
check_hand_install() {
    local unit f
    local -a old=() enabled=()
    for unit in yubikey-anycast.service yubikey-partition.service; do
        f=$SYSROOT/etc/systemd/system/$unit
        [[ -e $f && $(readlink -f -- "$f") != /dev/null ]] || continue
        enabled=("$SYSROOT"/etc/systemd/system/*.wants/"$unit")
        if [[ ${#enabled[@]} -gt 0 ]]; then
            note "/etc/systemd/system/$unit, installed by hand, hides the package's unit (which runs $DEST/${unit%.service}.sh). To use the package's:" \
                 "sudo systemctl disable $unit" \
                 "sudo rm /etc/systemd/system/$unit" \
                 "sudo systemctl daemon-reload" \
                 "sudo systemctl enable $unit" \
                 "sudo systemctl try-restart $unit"
        else
            note "/etc/systemd/system/$unit, installed by hand, hides the package's unit (which runs $DEST/${unit%.service}.sh). To use the package's:" \
                 "sudo rm /etc/systemd/system/$unit" \
                 "sudo systemctl daemon-reload"
        fi
    done
    for f in yubikey-db.sh yubikey-anycast.sh yubikey-partition.sh; do
        if [[ -e $SYSROOT/usr/local/sbin/$f ]]; then old+=("/usr/local/sbin/$f"); fi
    done
    if [[ ${#old[@]} -gt 0 ]]; then
        note "${old[*]}: copies installed by hand, which the package's units don't use. Remove them when nothing else does."
    fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case $1 in
        -y|--yes)      YES=1; shift ;;
        -n|--check)    CHECK=1; shift ;;
        --radiusd)     [[ $# -ge 2 ]] || usage_error "--radiusd needs a file"; RADIUSD=$2; shift 2 ;;
        -h|--help)     usage; exit 0 ;;
        -V|--version)  printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
        -*)            usage_error "unknown option '$1'" ;;
        *)             [[ -z $DEB ]] || usage_error "more than one package given"; DEB=$1; shift ;;
    esac
done

if [[ $CHECK == 0 && $NEED_ROOT == 1 && $EUID -ne 0 ]]; then
    die "run it as root: sudo $0${*:+ $*}"
fi

# The package: the one given, or the newest next to this script.
if [[ -z $DEB ]]; then
    debs=("$HERE"/radiator-yubikey_*_all.deb)
    if [[ ${#debs[@]} -gt 0 ]]; then DEB=$(printf '%s\n' "${debs[@]}" | sort -V | tail -1); fi
fi
deb_version=''
if [[ -n $DEB ]]; then
    [[ -f $DEB ]] || die "$DEB: no such file"
    [[ $(dpkg-deb -f "$DEB" Package 2>/dev/null) == radiator-yubikey ]] || die "$DEB is not a radiator-yubikey package"
    deb_version=$(dpkg-deb -f "$DEB" Version)
    DEB=$(realpath -- "$DEB")
    if [[ -e $SYSROOT$DEST/.git ]]; then
        die "$DEST is a git clone, and the package would install its files over it: move it away first, or use it without the package"
    fi
fi

printf '%s %s\n' "$PROG" "$VERSION"
find_radiator
report_radiator

installed=$(installed_version radiator-yubikey) || installed=''
if [[ -n $DEB ]]; then
    printf 'Package:   radiator-yubikey %s (%s); installed: %s\n' "$deb_version" "$DEB" "${installed:-none}"
elif [[ -n $installed ]]; then
    printf 'Package:   radiator-yubikey %s, installed\n' "$installed"
else
    printf 'Package:   radiator-yubikey not installed, and no package to install\n'
    [[ $CHECK == 0 ]] || MISSING=1
fi

if [[ $CHECK == 1 ]]; then
    echo
    echo "Packages:"
    for p in "${PACKAGES[@]}"; do
        if v=$(installed_version "$p"); then
            printf '  %-8s %s %s\n' ok "$p" "$v"
        else
            printf '  %-8s %s\n' missing "$p"
            MISSING=1
        fi
    done
else
    printf '\nInstalling with %s:\n' "$APT_GET"
    printf '%s\n' "${PACKAGES[*]}" | fold -s -w 76 | sed 's/ *$//; s/^/  /'
    if [[ -n $DEB ]]; then printf '  %s\n' "$DEB"; fi
    # With no terminal, debconf can't ask anything (none of these packages
    # asks), and says so for each package unless told.
    if [[ ! -t 0 ]]; then export DEBIAN_FRONTEND=noninteractive; fi
    "$APT_GET" -qq update || die "$APT_GET update failed"
    "$APT_GET" install -y "${PACKAGES[@]}" ${DEB:+"$DEB"} || die "$APT_GET install failed"
fi

if [[ -n $RAD_RADIUSD ]]; then
    check_modules
    if [[ -z $RAD_PKG ]]; then check_source_install; fi
fi
if [[ -n $DEB || -n $installed ]]; then check_hand_install; fi

print_notes

if [[ $CHECK == 1 ]]; then
    if [[ $MISSING == 1 ]]; then
        printf '\nSomething is missing.\n'
    elif [[ ${#NOTES[@]} -gt 0 ]]; then
        printf '\nSomething is left to do.\n'
    else
        printf '\nNothing is missing.\n'
        exit 0
    fi
    exit 1
fi
if [[ -n $DEB ]]; then
    cat <<EOF

Done. The scripts are in $DEST, with the guide
(yubikey-db-guide.html): go on at its "Create the database". For SQLite:
  cd $DEST && sudo ./yubikey-db.sh init --owner radiator:radiator
EOF
else
    printf '\nDone.\n'
fi
