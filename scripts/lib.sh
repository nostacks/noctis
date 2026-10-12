#!/usr/bin/env bash

NOCTIS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
UPSTREAM_DIR="$NOCTIS_ROOT/upstream/ungoogled-chromium"
PLATFORM_DIR="$NOCTIS_ROOT/platform/macos"
BUILD_DIR="$NOCTIS_ROOT/build"
SRC_DIR="$BUILD_DIR/src"
CACHE_DIR="$BUILD_DIR/download_cache"
STAMP_DIR="$BUILD_DIR/stamps"
SHIM_DIR="$BUILD_DIR/bin"
PROFILE_DIR="$BUILD_DIR/profile"
DOMSUB_CACHE="$BUILD_DIR/domsubcache.tar.gz"
PRODUCT_NAME="Noctis"

HOST_CPU="$(uname -m)"
case "${NOCTIS_ARCH:-$HOST_CPU}" in
  arm64|aarch64) TARGET_CPU=arm64 ;;
  x86_64|x64) TARGET_CPU=x64 ;;
  *) TARGET_CPU="" ;;
esac

if [ -t 1 ]; then
  C_BOLD=$'\033[1m' C_DIM=$'\033[2m' C_RED=$'\033[31m' C_GREEN=$'\033[32m' C_YELLOW=$'\033[33m' C_ACCENT=$'\033[35m' C_RESET=$'\033[0m'
else
  C_BOLD="" C_DIM="" C_RED="" C_GREEN="" C_YELLOW="" C_ACCENT="" C_RESET=""
fi

log() { printf '%s==>%s %s%s%s\n' "$C_ACCENT" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
die() { printf '%serror:%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

chromium_version() { cat "$UPSTREAM_DIR/chromium_version.txt"; }
upstream_revision() { cat "$UPSTREAM_DIR/revision.txt"; }
noctis_version() { cat "$NOCTIS_ROOT/version.txt"; }

stamp_done() { [ -f "$STAMP_DIR/$1" ]; }
stamp() { mkdir -p "$STAMP_DIR" && date -u +%Y-%m-%dT%H:%M:%SZ > "$STAMP_DIR/$1"; }

require_upstream() {
  [ -f "$UPSTREAM_DIR/chromium_version.txt" ] || die "ungoogled-chromium is not checked out. Run ./noctis init first."
}

require_target() {
  [ -n "$TARGET_CPU" ] || die "unsupported architecture: ${NOCTIS_ARCH:-$HOST_CPU} (expected arm64 or x86_64)"
}

python_supported() {
  "$1" -c 'import sys; sys.exit(0 if (3, 11) <= sys.version_info[:2] <= (3, 13) else 1)' >/dev/null 2>&1
}

find_python() {
  local name path
  for name in "${NOCTIS_PYTHON:-python3.13}" python3.13 python3.12 python3.11 \
      /opt/homebrew/opt/python@3.13/bin/python3.13 \
      /opt/homebrew/opt/python@3.12/bin/python3.12 \
      /opt/homebrew/opt/python@3.11/bin/python3.11 \
      python3; do
    path="$(command -v "$name" 2>/dev/null)" || continue
    if python_supported "$path"; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

setup_env() {
  local python
  python="$(find_python)" || die "Python 3.11 to 3.13 is required (depot_tools does not support 3.14). Try: brew install python@3.13"
  mkdir -p "$SHIM_DIR"
  ln -sf "$python" "$SHIM_DIR/python3"
  ln -sf "$python" "$SHIM_DIR/python"
  export PATH="$SHIM_DIR:$PATH"
  export PYTHONDONTWRITEBYTECODE=1
  export PYTHONWARNINGS="ignore::SyntaxWarning"
  export DEPOT_TOOLS_UPDATE=0
  export VPYTHON_BYPASS="manually managed python not supported by chrome operations"
}

out_dir() {
  if [ "$1" = 1 ]; then
    printf '%s\n' "$SRC_DIR/out/Dev"
  else
    printf '%s\n' "$SRC_DIR/out/Release"
  fi
}

merge_gn_args() {
  awk '
    /^[[:space:]]*(#|$)/ { next }
    {
      eq = index($0, "=")
      if (eq == 0) next
      key = substr($0, 1, eq - 1)
      gsub(/[[:space:]]/, "", key)
      value = substr($0, eq + 1)
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      if (!(key in values)) order[++n] = key
      values[key] = value
    }
    END { for (i = 1; i <= n; i++) print order[i] "=" values[order[i]] }
  '
}

gn_args() {
  local dev="$1"
  {
    cat "$UPSTREAM_DIR/flags.gn" "$PLATFORM_DIR/flags.gn" "$NOCTIS_ROOT/flags.gn"
    printf 'target_cpu="%s"\n' "$TARGET_CPU"
    if [ "$dev" = 1 ]; then
      printf '%s\n' is_official_build=false is_component_build=true symbol_level=1
    fi
    if command -v sccache >/dev/null 2>&1; then
      printf '%s\n' 'cc_wrapper="sccache"'
    elif command -v ccache >/dev/null 2>&1; then
      printf '%s\n' 'cc_wrapper="env CCACHE_COMPILERCHECK=content CCACHE_SLOPPINESS=time_macros ccache"'
    fi
  } | merge_gn_args
}

stage_prune() {
  stamp_done prune && return
  log "Pruning prebuilt binaries"
  python3 "$UPSTREAM_DIR/utils/prune_binaries.py" "$SRC_DIR" "$UPSTREAM_DIR/pruning.list"
  stamp prune
}

stage_toolchain() {
  stamp_done toolchain && return
  log "Downloading Chromium toolchain (clang, rust, node, gn, build tools)"
  (
    cd "$SRC_DIR"
    python3 tools/clang/scripts/update.py
    python3 tools/clang/scripts/update.py --package objdump
    python3 tools/clang/scripts/update.py --package libclang
    python3 tools/rust/update_rust.py
    bash third_party/node/update_node_binaries
    if [ "$HOST_CPU" = arm64 ] && [ -d third_party/node/mac/node-darwin-arm64 ]; then
      rm -rf third_party/node/mac_arm64/node-darwin-arm64
      mkdir -p third_party/node/mac_arm64
      mv third_party/node/mac/node-darwin-arm64 third_party/node/mac_arm64/
    fi
  )
  python3 "$NOCTIS_ROOT/scripts/install_deps.py" "$SRC_DIR"
  stamp toolchain
}

stage_patches() {
  stamp_done patches && return
  log "Applying patches (ungoogled-chromium, macOS, Noctis)"
  python3 "$UPSTREAM_DIR/utils/patches.py" apply "$SRC_DIR" \
    "$UPSTREAM_DIR/patches" "$PLATFORM_DIR/patches" "$NOCTIS_ROOT/patches"
  stamp patches
}

stage_domsub() {
  stamp_done domsub && return
  [ -e "$DOMSUB_CACHE" ] && die "domain substitution was interrupted earlier. Run ./noctis reset and start again."
  log "Substituting Google domains"
  python3 "$UPSTREAM_DIR/utils/domain_substitution.py" apply \
    -r "$UPSTREAM_DIR/domain_regex.list" \
    -f "$UPSTREAM_DIR/domain_substitution.list" \
    -c "$DOMSUB_CACHE" \
    "$SRC_DIR"
  stamp domsub
}
