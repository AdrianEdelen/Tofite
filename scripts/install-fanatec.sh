#!/usr/bin/env bash

set -euo pipefail

# Simple deterministic installer for hid-fanatecff for the bazzite image build.
# This script is intended to be executed inside the image build environment
# (the build binds the repo at /ctx and runs this as root). It will:
#  - install required build packages
#  - clone or update the driver source
#  - build the kernel module against the image kernel-devel
#  - install the .ko and udev rules into the image
#  - run depmod

# Configurable via environment when invoked by the build system
REPO_URL=${REPO_URL:-"https://github.com/gotzl/hid-fanatecff.git"}
TMP_DIR=${TMP_DIR:-"/tmp/hid-fanatecff"}
MODULE_FILENAME=${MODULE_FILENAME:-"hid-fanatec.ko"}
UDEV_RULE_SRC=${UDEV_RULE_SRC:-"fanatec.rules"}
UDEV_RULE_DST=${UDEV_RULE_DST:-"/etc/udev/rules.d/99-fanatec.rules"}
CLEANUP=${CLEANUP:-true}

PACKAGES=(git make gcc kernel-devel-matched binutils-devel)
DNF_CMD=${DNF_CMD:-dnf5}

log() { printf '%s\n' "[install-fanatec] $*"; }
require_root() { [ "$(id -u)" -eq 0 ]; }

if ! require_root; then
	log "error: must be run as root inside the image build environment"
	exit 1
fi

# ensure dnf available
if ! command -v "${DNF_CMD}" >/dev/null 2>&1; then
	if command -v dnf >/dev/null 2>&1; then
		DNF_CMD=dnf
	else
		log "error: neither dnf5 nor dnf found"
		exit 1
	fi
fi

log "installing build packages: ${PACKAGES[*]}"
${DNF_CMD} install -y "${PACKAGES[@]}"

# clone or update
if [ -d "${TMP_DIR}" ]; then
	log "updating source in ${TMP_DIR}"
	git -C "${TMP_DIR}" fetch --depth 1 origin || true
	git -C "${TMP_DIR}" reset --hard origin/HEAD || true
else
	log "cloning ${REPO_URL} -> ${TMP_DIR}"
	git clone --depth 1 "${REPO_URL}" "${TMP_DIR}"
fi

KVER=$(uname -r)
MODULE_DIR="/usr/lib/modules/${KVER}/kernel/drivers/hid"

log "building module"
make -C "${TMP_DIR}"

log "installing module to ${MODULE_DIR}"
mkdir -p "${MODULE_DIR}"
if [ -f "${TMP_DIR}/${MODULE_FILENAME}" ]; then
	cp -f "${TMP_DIR}/${MODULE_FILENAME}" "${MODULE_DIR}/"
	chmod 644 "${MODULE_DIR}/${MODULE_FILENAME}"
else
	log "error: built module ${TMP_DIR}/${MODULE_FILENAME} not found"
	exit 1
fi

# udev rule
if [ -f "${TMP_DIR}/${UDEV_RULE_SRC}" ]; then
	log "installing udev rule ${UDEV_RULE_SRC} -> ${UDEV_RULE_DST}"
	install -m 644 "${TMP_DIR}/${UDEV_RULE_SRC}" "${UDEV_RULE_DST}"
	command -v udevadm >/dev/null 2>&1 && udevadm control --reload-rules || true
	command -v udevadm >/dev/null 2>&1 && udevadm trigger --action=add || true
else
	log "no udev rule ${UDEV_RULE_SRC} present; skipping"
fi

# update module deps
command -v depmod >/dev/null 2>&1 && depmod -a "${KVER}" || true

# cleanup
if [ "${CLEANUP}" = true ]; then
	rm -rf "${TMP_DIR}" || true
fi

log "fanatec driver install complete"

