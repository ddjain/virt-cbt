#!/usr/bin/env bash
# Explicitly install missing, self-contained client tools into a local directory.
set -euo pipefail

DEST=''
TMP_DIR=''
RELEASE_JSON=''
ASSET_URL=''
ASSET_DIGEST=''

usage() {
  echo 'Usage: bootstrap-tools.sh --dir DIRECTORY' >&2
}

log() {
  printf '[bootstrap] %s\n' "$*"
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

cleanup() {
  [[ -z ${TMP_DIR:-} ]] || rm -rf "$TMP_DIR"
}
trap cleanup EXIT

while (($#)); do
  case "$1" in
    --dir) DEST=${2-}; shift 2;;
    -h|--help) usage; exit 0;;
    *) usage; exit 2;;
  esac
done

[[ -n $DEST ]] || { usage; exit 2; }

need_virtctl=0
need_kube_burner=0
if have virtctl; then
  log "virtctl already available: $(command -v virtctl)"
else
  need_virtctl=1
fi
if have kube-burner; then
  log "kube-burner already available: $(command -v kube-burner)"
else
  need_kube_burner=1
fi

if ((need_virtctl == 0 && need_kube_burner == 0)); then
  log 'No tools need installation.'
  exit 0
fi

for tool in jq tar; do
  have "$tool" || die "$tool is required to bootstrap missing tools"
done
if ! have curl && ! have wget; then
  die 'curl or wget is required to bootstrap missing tools'
fi
if ! have sha256sum && ! have shasum && ! have openssl; then
  die 'sha256sum, shasum, or openssl is required to verify downloaded tools'
fi

case "$(uname -s)" in
  Darwin) virtctl_os=darwin; kube_burner_os=darwin;;
  Linux) virtctl_os=linux; kube_burner_os=linux;;
  *) die "unsupported operating system: $(uname -s)";;
esac
case "$(uname -m)" in
  x86_64|amd64) virtctl_arch=amd64; kube_burner_arch=x86_64;;
  arm64|aarch64) virtctl_arch=arm64; kube_burner_arch=arm64;;
  *) die "unsupported machine architecture: $(uname -m)";;
esac

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/odf-cbt-bootstrap.XXXXXX")
mkdir -p "$DEST"

fetch_text() {
  local url=$1
  if have curl; then
    curl --fail --location --silent --show-error --retry 3 "$url"
  else
    wget -qO- "$url"
  fi
}

download() {
  local url=$1 output=$2
  if have curl; then
    curl --fail --location --silent --show-error --retry 3 --output "$output" "$url"
  else
    wget -qO "$output" "$url"
  fi
}

sha256_file() {
  local file=$1
  if have sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  elif have shasum; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    openssl dgst -sha256 "$file" | sed 's/^.*= //'
  fi
}

fetch_release() {
  local repository=$1 version=${2-}
  if [[ -n $version ]]; then
    RELEASE_JSON=$(fetch_text "https://api.github.com/repos/$repository/releases/tags/$version")
  else
    RELEASE_JSON=$(fetch_text "https://api.github.com/repos/$repository/releases/latest")
  fi
}

select_asset() {
  local name=$1 digest
  ASSET_URL=$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .browser_download_url' <<<"$RELEASE_JSON") || die "release asset not found: $name"
  digest=$(jq -er --arg name "$name" '.assets[] | select(.name == $name) | .digest' <<<"$RELEASE_JSON") || die "published checksum not found: $name"
  ASSET_DIGEST=${digest#sha256:}
  [[ $ASSET_DIGEST =~ ^[[:xdigit:]]{64}$ ]] || die "invalid published checksum for $name"
}

verify_and_install() {
  local source=$1 destination=$2 expected=$3 actual
  actual=$(sha256_file "$source")
  [[ $actual == "$expected" ]] || die "SHA-256 mismatch for $(basename "$source")"
  cp "$source" "$destination"
  chmod 0755 "$destination"
}

install_virtctl() {
  local version asset archive
  [[ $need_virtctl == 1 ]] || return

  version=${VIRTCTL_VERSION:-}
  if [[ -z $version ]]; then
    version=$(fetch_text 'https://storage.googleapis.com/kubevirt-prow/release/kubevirt/kubevirt/stable.txt')
  fi
  version=${version//$'\r'/}
  version=${version//$'\n'/}
  [[ $version == v* ]] || die "invalid virtctl version: $version"

  fetch_release 'kubevirt/kubevirt' "$version"
  asset="virtctl-${version}-${virtctl_os}-${virtctl_arch}"
  select_asset "$asset"
  archive="$TMP_DIR/$asset"
  download "$ASSET_URL" "$archive"
  verify_and_install "$archive" "$DEST/virtctl" "$ASSET_DIGEST"
  "$DEST/virtctl" version --client >/dev/null
  log "installed virtctl $version in $DEST"
}

install_kube_burner() {
  local version asset archive extract_dir actual
  [[ $need_kube_burner == 1 ]] || return

  version=${KUBE_BURNER_VERSION:-}
  fetch_release 'kube-burner/kube-burner' "$version"
  if [[ -z $version ]]; then
    version=$(jq -er '.tag_name' <<<"$RELEASE_JSON") || die 'latest kube-burner release has no tag'
  fi
  [[ $version == v* ]] || die "invalid kube-burner version: $version"

  asset="kube-burner-V${version#v}-${kube_burner_os}-${kube_burner_arch}.tar.gz"
  select_asset "$asset"
  archive="$TMP_DIR/$asset"
  extract_dir="$TMP_DIR/kube-burner"
  mkdir -p "$extract_dir"
  download "$ASSET_URL" "$archive"
  actual=$(sha256_file "$archive")
  [[ $actual == "$ASSET_DIGEST" ]] || die "SHA-256 mismatch for $asset"
  tar -xzf "$archive" -C "$extract_dir"
  [[ -f $extract_dir/kube-burner ]] || die "archive does not contain kube-burner"
  cp "$extract_dir/kube-burner" "$DEST/kube-burner"
  chmod 0755 "$DEST/kube-burner"
  "$DEST/kube-burner" version >/dev/null
  log "installed kube-burner $version in $DEST"
}

install_virtctl
install_kube_burner
