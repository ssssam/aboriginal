#!/bin/bash

# Extend minimal native build environment into a seed for Gentoo Catalyst.

# This doesn't quite create an official Gentoo Stage 1.  We use busybox instead
# of gnu tools, we're uClibc-based instead of glibc-based, and we use our
# existing toolchain (with distcc acceleration) instead of asking portage
# to build one.  That said, this should be enough to run Catalyst and produce
# official Stage 1, Stage 2, and Stage 3 images.

# GFS used:
# setup-base-packages.sh
#   strace, Python, ncurses, bash, tar, patch, findutils, file, pax-utils,
#   shadow
# setup-portage.sh
#   /etc/passwd (root and portage), /etc/group (root and portage)
#   portage

# Download all the source tarballs we haven't got up-to-date copies of.

# The tarballs are downloaded into the "packages" directory, which is
# created as needed.

source sources/include.sh || exit 1

# Find path to our working directory.

[ $# -ne 1 ] && echo "usage: $0 FILENAME" >&2 && exit 1
[ "$1" != "/dev/null" ] && [ -e "$1" ] && echo "$1" exists && exit 0

# We use a lot of our own directories because we may have the same packages
# as the aboriginal build, but use different versions.  So keep things separate
# so they don't interfere.

MYDIR="$(dirname "$(readlink -f "$(which "$0")")")"
IMAGENAME="${MYDIR/*\//}"
PATCHDIR="$MYDIR/patches"
SRCDIR="$SRCDIR/$IMAGENAME" && mkdir -p "$SRCDIR" || dienow
WORK="$WORK/$IMAGENAME" && blank_tempdir "$WORK"
SRCTREE="$WORK"

echo "=== Download source code."

EXTRACT_ALL=1

URL=http://zlib.net/zlib-1.2.5.tar.bz2 \
SHA1=543fa9abff0442edca308772d6cef85557677e02 \
maybe_fork "download || dienow"

URL=http://ftp.gnu.org/pub/gnu/ncurses/ncurses-5.7.tar.gz \
SHA1=8233ee56ed84ae05421e4e6d6db6c1fe72ee6797 \
maybe_fork "download || dienow"

URL=http://python.org/ftp/python/2.6.5/Python-2.6.5.tar.bz2 \
SHA1=24c94f5428a8c94c9d0b316e3019fee721fdb5d1 \
maybe_fork "download || dienow"

URL=http://ftp.gnu.org/gnu/bash/bash-3.2.tar.gz \
SHA1=fe6466c7ee98061e044dae0347ca5d1a8eab4a0d \
maybe_fork "download || dienow"

URL=http://www.samba.org/ftp/rsync/src/rsync-3.0.7.tar.gz \
SHA1=63426a1bc71991d93159cd522521fbacdafb7a61 \
maybe_fork "download || dienow"

URL=http://ftp.gnu.org/gnu/patch/patch-2.5.9.tar.gz \
SHA1=9a69f7191576549255f046487da420989d2834a6 \
maybe_fork "download || dienow"

URL=ftp://ftp.astron.com/pub/file/file-5.03.tar.gz \
SHA1=f659a4e1fa96fbdc99c924ea8e2dc07319f046c1 \
maybe_fork "download || dienow"

URL=http://dev.gentoo.org/~zmedico/portage/archives/portage-2.1.8.tar.bz2 \
SHA1=390c97f3783af2d9e52482747ead3681655ea9c3 \
maybe_fork "download || dienow"

echo === Got all source.

cleanup_oldfiles

cp -a "$MYDIR/build/." "$WORK" &&
cp -a "$MYDIR/files" "$WORK" || exit 1

if [ "$1" != "/dev/null" ]
then
  cd "$TOP" &&
  mksquashfs "$WORK" "$1" -noappend -all-root || dienow
fi