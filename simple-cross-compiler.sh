#!/bin/bash

# Build a cross compiler for the specified target.

# Get lots of predefined environment variables and shell functions.

source sources/include.sh || exit 1

# Parse the sources/targets/$1 directory

read_arch_dir "$1"

# If this target has a base architecture that's already been built, use that.

check_for_base_arch || exit 0

# Ok, we have work to do.  Announce start of stage.

echo "=== Building $STAGE_NAME"

# Build binutils, gcc, and ccwrap

FROM_ARCH= PROGRAM_PREFIX="${ARCH}-" build_section binutils
FROM_ARCH= PROGRAM_PREFIX="${ARCH}-" build_section gcc
FROM_ARCH= PROGRAM_PREFIX="${ARCH}-" build_section ccwrap

# Build C Library

build_section linux-headers
HOST_UTILS=1 build_section uClibc

cat > "${STAGE_DIR}"/README << EOF &&
Cross compiler for $ARCH
From http://impactlinux.com/fwl

To use: Add the "bin" subdirectory to your \$PATH, and use "$ARCH-cc" as
your compiler.

The syntax used to build the Linux kernel is:

  make ARCH=${KARCH} CROSS_COMPILE=${ARCH}-

EOF

# Strip the binaries

if [ -z "$SKIP_STRIP" ]
then
  cd "$STAGE_DIR"
  for i in `find bin -type f` `find "$CROSS_TARGET" -type f`
  do
    strip "$i" 2> /dev/null
  done
fi

# Tar it up

create_stage_tarball

# A quick hello world program to test the cross compiler out.
# Build hello.c dynamic, then static, to verify header/library paths.

echo "Sanity test: building Hello World."

"${ARCH}-gcc" -Os "${SOURCES}/toys/hello.c" -o "$WORK"/hello &&
"${ARCH}-gcc" -Os -static "${SOURCES}/toys/hello.c" -o "$WORK"/hello &&
if [ ! -z "$CROSS_SMOKE_TEST" ] && which qemu-"${QEMU_TEST}" > /dev/null
then
  [ x"$(qemu-"${QEMU_TEST}" "${WORK}"/hello)" == x"Hello world!" ] &&
  echo Cross-toolchain seems to work.
fi

[ $? -ne 0 ] && dienow

echo -e "\e[32mCross compiler toolchain build complete.\e[0m"