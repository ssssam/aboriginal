#!/bin/echo "This file is sourced, not run"

# Lots of reusable functions.  This file is sourced, not run.

source sources/utility_functions.sh

# Output path to cross compiler.

cc_path()
{
  local i

  # Output cross it if exists, else simple.  If neither exists, output simple.

  for i in "$BUILD"/{,simple-}cross-compiler-"$1/bin"
  do
    [ -e "$i/$1-cc" ] && break
  done
  echo -n "$i:"
}

read_arch_dir()
{
  # Get target platform from first command line argument.

  ARCH_NAME="$1"
  if [ ! -f "${SOURCES}/targets/${ARCH_NAME}/settings" ]
  then
    echo "Supported architectures: "
    (cd "${SOURCES}/targets" && ls)

    exit 1
  fi

  # Read the relevant config file.

  ARCH="$ARCH_NAME"
  CONFIG_DIR="${SOURCES}/targets"
  source "${CONFIG_DIR}/${ARCH}/settings"

  # Which platform are we building for?

  export WORK="${BUILD}/temp-$ARCH_NAME"

  # Say "unknown" in two different ways so it doesn't assume we're NOT
  # cross compiling when the host and target are the same processor.  (If host
  # and target match, the binutils/gcc/make builds won't use the cross compiler
  # during root-filesystem.sh, and the host compiler links binaries against the
  # wrong libc.)
  export_if_blank CROSS_HOST=`uname -m`-walrus-linux
  export_if_blank CROSS_TARGET=${ARCH}-unknown-linux

  # Setup directories and add the cross compiler to the start of the path.

  STAGE_DIR="$BUILD/${STAGE_NAME}-${ARCH_NAME}"

  blank_tempdir "$STAGE_DIR"
  blank_tempdir "$WORK"

  export PATH="$(cc_path "$ARCH")$PATH"
  [ ! -z "$HOST_ARCH" ] && [ "$HOST_ARCH" != "$ARCH" ] &&
    PATH="$(cc_path "$HOST_ARCH")$PATH"

  DO_CROSS="CROSS_COMPILE=${ARCH}-"

  return 0
}

# Note that this sources the file, rather than calling it as a separate
# process.  That way it can set environment variables if it wants to.

build_section()
{
  # Don't build anything statically in host-tools, glibc is broken.
  # See http://people.redhat.com/drepper/no_static_linking.html for
  # insane rant from the glibc maintainer about why he doesn't care.
  is_in_list $1 $BUILD_STATIC && [ ! -z "$ARCH" ] && STATIC_FLAGS="--static"

  OLDCPUS=$CPUS
  is_in_list $1 $DEBUG_PACKAGE && CPUS=1

  if [ -e "$SOURCES/sections/$1".build ]
  then
    setupfor "$1"
    . "$SOURCES/sections/$1".build
    cleanup
  else
    echo "=== build section $1"
    . "$SOURCES"/sections/"$1".sh
  fi
  CPUS=$OLDCPUS
}

# Find appropriate miniconfig file

getconfig()
{
  for i in $(is_in_list $1 $USE_UNSTABLE && echo {$ARCH_NAME,$ARCH}/miniconfig-alt-$1) \
    {$ARCH_NAME,$ARCH}/miniconfig-$1
  do
    [ -f "$CONFIG_DIR/$i" ] && cat "$CONFIG_DIR/$i" && return
  done

  # Output baseconfig, then append $1_CONFIG (converting $1 to uppercase)
  cat "$SOURCES/baseconfig-$1"
  eval "echo \"\${$(echo $1 | tr a-z A-Z)_CONFIG}\""
}

# Find all files in $STAGE_DIR newer than $CURSRC.

recent_binary_files()
{
  PREVIOUS=
  (cd "$STAGE_DIR" || dienow
   find . -depth -newer "$CURSRC/FWL-TIMESTAMP" \
     | sed -e 's/^.//' -e 's/^.//' -e '/^$/d'
  ) | while read i
  do
    TEMP="${PREVIOUS##"$i"/}"

    if [ $[${#PREVIOUS}-${#TEMP}] -ne $[${#i}+1] ]
    then
      # Because the expanded $i might have \ chars in it, that's why.
      echo -n "$i"
      echo -ne '\0'
    fi
    PREVIOUS="$i"
  done
}

# Strip the version number off a tarball

cleanup()
{
  # If package build exited with an error, do not continue.

  [ $? -ne 0 ] && dienow

  if [ ! -z "$BINARY_PACKAGE_TARBALLS" ]
  then
    TARNAME="$PACKAGE-$STAGE_NAME-${ARCH_NAME}".tar.bz2
    echo -n Creating "$TARNAME"
    { recent_binary_files | xargs -0 tar -cjvf \
        "$BUILD/${TARNAME}" -C "$STAGE_DIR" || dienow
    } | dotprogress
  fi

  if [ ! -z "$NO_CLEANUP" ]
  then
    echo "skip cleanup $PACKAGE $@"
    return
  fi

  # Loop deleting directories

  cd "$WORK" || dienow
  for i in $WORKDIR_LIST
  do
    echo "cleanup $i"
    rm -rf "$i" || dienow
  done
  WORKDIR_LIST=
}

# Give filename.tar.ext minus the version number.

noversion()
{
  echo "$1" | sed -e 's/-*\(\([0-9\.]\)*\([_-]rc\)*\(-pre\)*\([0-9][a-zA-Z]\)*\)*\(\.tar\..z2*\)$/'"$2"'\6/'
}

# Given a filename.tar.ext, return the version number.

getversion()
{
  echo "$1" | sed -e 's/.*-\(\([0-9\.]\)*\([_-]rc\)*\(-pre\)*\([0-9][a-zA-Z]\)*\)*\(\.tar\..z2*\)$/'"$2"'\1/'
}

# Apply any patches to this package
patch_package()
{
  ls "$PATCHDIR/${PACKAGE}"-* 2> /dev/null | sort | while read i
  do
    if [ -f "$i" ]
    then
      echo "Applying $i"
      (cd "${SRCTREE}/${PACKAGE}" &&
       patch -p1 -i "$i" &&
       sha1file "$i" >> "$SHA1FILE") ||
        ([ -z "$ALLOW_PATCH_FAILURE" ] && dienow)
    fi
  done
}

# Extract tarball named in $1 and apply all relevant patches into
# "$BUILD/packages/$1".  Record sha1sum of tarball and patch files in
# sha1-for-source.txt.  Re-extract if tarball or patches change.

extract_package()
{
  mkdir -p "$SRCTREE" || dienow

  # Figure out whether we're using an unstable package.

  PACKAGE="$1"
  is_in_list "$PACKAGE" $USE_UNSTABLE && PACKAGE=alt-"$PACKAGE"

  # Announce to the world that we're cracking open a new package

  echo "=== $PACKAGE ($ARCH_NAME $STAGE_NAME)"
  set_titlebar "$ARCH_NAME $STAGE_NAME $PACKAGE"

  # Find tarball, and determine type

  FILENAME="$(ls -tc "$SRCDIR/${PACKAGE}-"*.tar* 2>/dev/null | head -n 1)"
  DECOMPRESS=""
  [ "$FILENAME" != "${FILENAME/%\.tar\.bz2/}" ] && DECOMPRESS="j"
  [ "$FILENAME" != "${FILENAME/%\.tar\.gz/}" ] && DECOMPRESS="z"

  # If the source tarball doesn't exist, but the extracted directory is there,
  # assume everything's ok.

  SHA1FILE="$SRCTREE/$PACKAGE/sha1-for-source.txt"
  if [ -z "$FILENAME" ]
  then
    [ ! -e "$SRCTREE/$PACKAGE" ] && dienow "No tarball for $PACKAGE"

    # If the sha1sum file isn't there, re-patch the package.
    [ ! -e "$SHA1FILE" ] && patch_package
    return 0
  fi

  # Check the sha1 list from the previous extract.  If the source is already
  # up to date (including patches), keep it.

  SHA1TAR="$(sha1file "$FILENAME")"
  SHALIST=$(cat "$SHA1FILE" 2> /dev/null)
  if [ ! -z "$SHALIST" ]
  then
    for i in "$SHA1TAR" $(sha1file "$PATCHDIR/$PACKAGE"-* 2>/dev/null)
    do
      # Is this sha1 in the file?
      if [ -z "$(echo "$SHALIST" | sed -n "s/$i/$i/p" )" ]
      then
        SHALIST=missing
        break
      fi
      # Remove it
      SHALIST="$(echo "$SHALIST" | sed "s/$i//" )"
    done
    # If we matched all the sha1sums, nothing more to do.
    [ -z "$SHALIST" ] && return 0
  fi

  # Re-extract the package, deleting the old one (if any)..

  echo -n "Extracting '$PACKAGE'"
  (
    UNIQUE=$(readlink /proc/self)
    trap 'rm -rf "$BUILD/temp-'$UNIQUE'"' EXIT
    rm -rf "$SRCTREE/$PACKAGE" 2>/dev/null
    mkdir -p "$BUILD"/{temp-$UNIQUE,packages} || dienow

    { tar -xv${DECOMPRESS} -f "$FILENAME" -C "$BUILD/temp-$UNIQUE" || dienow
    } | dotprogress

    mv "$BUILD/temp-$UNIQUE/"* "$SRCTREE/$PACKAGE" &&
    echo "$SHA1TAR" > "$SHA1FILE"
  )

  [ $? -ne 0 ] && dienow

  patch_package
}

# Confirm that a file has the appropriate checksum (or exists but SHA1 is blank)
# Delete invalid file.

confirm_checksum()
{
  SUM="$(sha1file "$SRCDIR/$FILENAME" 2>/dev/null)"
  if [ x"$SUM" == x"$SHA1" ] || [ -z "$SHA1" ] && [ -f "$SRCDIR/$FILENAME" ]
  then
    if [ -z "$SHA1" ]
    then
      echo "No SHA1 for $FILENAME ($SUM)"
    else
      echo "Confirmed $FILENAME"
    fi

    # Preemptively extract source packages?

    [ -z "$EXTRACT_ALL" ] && return 0
    extract_package "$BASENAME"
    return $?
  fi

  # If there's a corrupted file, delete it.  In theory it would be nice
  # to resume downloads, but wget creates "*.1" files instead.

  rm "$SRCDIR/$FILENAME" 2> /dev/null

  return 1
}

# Attempt to obtain file from a specific location

download_from()
{
  # Return success if we already have a valid copy of the file

  confirm_checksum && return 0

  # If we have another source, try to download file from there.

  [ -z "$1" ] && return 1
  wget -t 2 -T 20 -O "$SRCDIR/$FILENAME" "$1" ||
    (rm "$SRCDIR/$FILENAME"; return 2)
  touch -c "$SRCDIR/$FILENAME"

  confirm_checksum
}

# Confirm a file matches sha1sum, else try to download it from mirror list.

download()
{
  FILENAME=`echo "$URL" | sed 's .*/  '`
  [ -z "$RENAME" ] || FILENAME="$(echo "$FILENAME" | sed -r "$RENAME")"
  ALTFILENAME=alt-"$(noversion "$FILENAME" -0)"

  echo -ne "checking $FILENAME\r"

  # Update timestamps on both stable and unstable tarballs (if any)
  # so cleanup_oldfiles doesn't delete stable when we're building unstable
  # or vice versa

  touch -c "$SRCDIR"/{"$FILENAME","$ALTFILENAME"} 2>/dev/null

  # Give package name, minus file's version number and archive extension.
  BASENAME="$(noversion "$FILENAME" | sed 's/\.tar\..z2*$//')"

  # If unstable version selected, try from listed location, and fall back
  # to PREFERRED_MIRROR.  Do not try normal mirror locations for unstable.

  if is_in_list "$BASENAME" $USE_UNSTABLE
  then
    # If extracted source directory exists, don't download alt-tarball.
    [ -e "$SRCTREE/alt-$BASENAME" ] && return 0

    # Download new one as alt-packagename.tar.ext
    FILENAME="$ALTFILENAME"
    SHA1=

    ([ ! -z "$PREFERRED_MIRROR" ] &&
      download_from "$PREFERRED_MIRROR/$ALTFILENAME") ||
      download_from "$UNSTABLE"
    return $?
  fi

  # If environment variable specifies a preferred mirror, try that first.

  if [ ! -z "$PREFERRED_MIRROR" ]
  then
    download_from "$PREFERRED_MIRROR/$FILENAME" && return 0
  fi

  # Try original location, then mirrors.
  # Note: the URLs in mirror list cannot contain whitespace.

  download_from "$URL" && return 0
  for i in $MIRROR_LIST
  do
    download_from "$i/$FILENAME" && return 0
  done

  # Return failure.

  echo "Could not download $FILENAME"
  echo -en "\e[0m"
  return 1
}

# Clean obsolete files out of the source directory

START_TIME=`date +%s`

cleanup_oldfiles()
{
  # wait for asynchronous downloads to complete

  wait

  for i in "${SRCDIR}"/*
  do
    if [ -f "$i" ] && [ "$(date +%s -r "$i")" -lt "${START_TIME}" ]
    then
      echo Removing old file "$i"
      rm -rf "$i"
    fi
  done
}

# Create a working directory under TMPDIR, deleting existing contents (if any),
# and tracking created directories so cleanup can delete them automatically.

blank_workdir()
{
  WORKDIR_LIST="$1 $WORKDIR_LIST"
  NO_CLEANUP= blank_tempdir "$WORK/$1"
  cd "$WORK/$1" || dienow
}

# Extract package $1

setupfor()
{
  export WRAPPY_LOGPATH="$BUILD/logs/cmdlines.${ARCH_NAME}.${STAGE_NAME}.setupfor"

  # Make sure the source is already extracted and up-to-date.
  extract_package "$1" || exit 1

  # Delete old working copy (even in the NO_CLEANUP case) then make a new
  # tree of links to the package cache.

  echo "Snapshot '$PACKAGE'..."

  if [ -z "$REUSE_CURSRC" ]
  then
    blank_workdir "$PACKAGE"
    CURSRC="$(pwd)"
  fi

  [ -z "$SNAPSHOT_SYMLINK" ] && LINKTYPE="l" || LINKTYPE="s"
  cp -${LINKTYPE}fR "$SRCTREE/$PACKAGE/"* "$CURSRC"

  if [ $? -ne 0 ]
  then
    echo "$PACKAGE not found.  Did you run download.sh?" >&2
    dienow
  fi

  cd "$CURSRC" || dienow
  export WRAPPY_LOGPATH="$BUILD/logs/cmdlines.${ARCH_NAME}.${STAGE_NAME}.$1"

  # Ugly bug workaround: timestamp granularity in a lot of filesystems is only
  # 1 second, so find -newer misses things installed in the same second, so we
  # make sure it's a new second before we start actually doing anything.

  if [ ! -z "$BINARY_PACKAGE_TARBALLS" ]
  then
    touch "$CURSRC/FWL-TIMESTAMP" || dienow
    TIME=$(date +%s)
    while true
    do
      [ $TIME != "$(date +%s)" ] && break
      sleep .1
    done
  fi
}

# Figure out what version of a package we last built

get_download_version()
{
  getversion $(sed -n 's@URL=.*/\(.[^ ]*\).*@\1@p' "$TOP/download.sh" | grep ${1}-)
}

# Identify subversion or mercurial revision, or release number

identify_release()
{
  if is_in_list "$1" $USE_UNSTABLE
  then
    for i in "b" ""
    do
      FILE="$(echo "$SRCDIR/alt-$1-"*.tar.$i*)"
      if [ -f "$FILE" ]
      then
        GITID="$(${i}zcat "$FILE" 2> /dev/null | git get-tar-commit-id 2>/dev/null)"
        if [ ! -z "$GITID" ]
        then
          # The first dozen chars should form a unique id.

          echo $GITID | sed 's/^\(................\).*/git \1/'
          return
        fi
      fi
    done

    # Need to extract unstable packages to determine source control version.

    extract_package "$1" >&2
    DIR="${BUILD}/packages/alt-$1"

    if [ -d "$DIR/.svn" ]
    then
      ( cd "$DIR"; echo subversion rev \
        $(svn info | sed -n "s/^Revision: //p")
      )
      return 0
    elif [ -d "$DIR/.hg" ]
    then
      ( echo mercurial rev \
          $(hg tip | sed -n 's/changeset: *\([0-9]*\).*/\1/p')
      )
      return 0
    fi
  fi

  echo release version $(get_download_version $1)
}

# Create a README identifying package versions in current build.

do_readme()
{
  # Grab FWL version number

  [ -z "$FWL_VERS" ] &&
    FWL_VERS="mercurial rev $(cd "$TOP"; hg tip 2>/dev/null | sed -n 's/changeset: *\([0-9]*\).*/\1/p')"

  cat << EOF
Built on $(date +%F) from:

  Build script:
    Firmware Linux (http://landley.net/code/firmware) $FWL_VERS

  Base packages:
    uClibc (http://uclibc.org) $(identify_release uClibc)
    BusyBox (http://busybox.net) $(identify_release busybox)
    Linux (http://kernel.org/pub/linux/kernel) $(identify_release linux)

  Toolchain packages:
    Binutils (http://www.gnu.org/software/binutils/) $(identify_release binutils)
    GCC (http://gcc.gnu.org) $(identify_release gcc-core)
    gmake (http://www.gnu.org/software/make) $(identify_release make)
    bash (ftp://ftp.gnu.org/gnu/bash) $(identify_release bash)

  Optional packages:
    Toybox (http://landley.net/code/toybox) $(identify_release toybox)
    distcc (http://distcc.samba.org) $(identify_release distcc)
    uClibc++ (http://cxx.uclibc.org) $(identify_release uClibc++)
EOF
}

# When building with a base architecture, symlink to the base arch name.

link_arch_name()
{
  [ "$ARCH" == "$ARCH_NAME" ] && return 0

  rm -rf "$BUILD/$2" &&
  ln -s "$1" "$BUILD/$2" || dienow
}

# Check if this target has a base architecture that's already been built.
# If so, link to it and exit now.

check_for_base_arch()
{
  # If we're building something with a base architecture, symlink to actual
  # target.

  if [ "$ARCH" != "$ARCH_NAME" ]
  then
    link_arch_name $STAGE_NAME-{"$ARCH","$ARCH_NAME"}
    [ -e $STAGE_NAME-"$ARCH".tar.bz2 ] &&
      link_arch_name $STAGE_NAME-{"$ARCH","$ARCH_NAME"}.tar.bz2

    if [ -e "$BUILD/$STAGE_NAME-$ARCH" ]
    then
      echo "=== Using existing ${STAGE_NAME}-$ARCH"

      return 1
    else
      mkdir -p "$BUILD/$STAGE_NAME-$ARCH" || dienow
    fi
  fi
}

create_stage_tarball()
{
  # Remove the temporary directory, if empty

  rmdir "$WORK" 2>/dev/null

  # Handle linking to base architecture if we just built a derivative target.

  cd "$BUILD" || dienow
  link_arch_name $STAGE_NAME-{$ARCH,$ARCH_NAME}

  if [ -z "$NO_STAGE_TARBALLS" ]
  then
    echo -n creating "$STAGE_NAME-${ARCH}".tar.bz2

    { tar cjvf "$STAGE_NAME-${ARCH}".tar.bz2 "$STAGE_NAME-${ARCH}" || dienow
    } | dotprogress

    link_arch_name $STAGE_NAME-{$ARCH,$ARCH_NAME}.tar.bz2
  fi
}

# Create colon-separated path for $HOSTTOOLS and all fallback directories
# (Fallback directories are to support ccache and distcc on the host.)

hosttools_path()
{
  local X

  echo -n "$HOSTTOOLS"
  X=1
  while [ -e "$HOSTTOOLS/fallback-$X" ]
  do
    echo -n ":$HOSTTOOLS/fallback-$X"
    X=$[$X+1]
  done
}
