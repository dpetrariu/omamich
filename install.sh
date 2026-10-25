#!/usr/bin/env bash
# Install or update Omamich, the Immich client for the Omarchy shell.
#
#   curl -fsSL https://raw.githubusercontent.com/dpetrariu/omamich/main/install.sh | bash
#
# or, from a checkout: ./install.sh
#
# It gets the code (or updates it), builds the backend, links the plugin into
# Omarchy, enables it and restarts the shell. Running it again updates.
#
# Options: --no-restart  leave the shell running (restart it yourself later)
# Environment: OMAMICH_DIR  where the code lives (default ~/.local/share/omamich-plugin)
#              OMAMICH_REPO the git repository to clone
set -euo pipefail

repo="${OMAMICH_REPO:-https://github.com/dpetrariu/omamich.git}"
dir="${OMAMICH_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/omamich-plugin}"
restart=true

for arg in "$@"; do
  case "$arg" in
    --no-restart) restart=false ;;
    -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]:-/dev/null}" 2>/dev/null || true; exit 0 ;;
    *) echo "Unknown option: $arg" >&2; exit 2 ;;
  esac
done

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
fail() { printf '\033[31merror:\033[0m %s\n' "$*" >&2; exit 1; }

command -v omarchy >/dev/null || fail "Omamich is an Omarchy shell plugin; Omarchy 4 is required."
command -v omarchy-shell >/dev/null || fail "This Omarchy has no shell plugins yet; update Omarchy (omarchy update) and run this again."

# Run from inside a checkout: use it instead of cloning.
here=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -f "$here/manifest.json" ]] && grep -q '"id": "omamich"' "$here/manifest.json"; then
    dir="$here"
  fi
fi

# Build tools: a C compiler (SQLite is built in), git, make.
missing=()
command -v git >/dev/null || missing+=(git)
command -v make >/dev/null || missing+=(make)
command -v cc >/dev/null || missing+=(base-devel)
if (( ${#missing[@]} )); then
  say "Installing build tools: ${missing[*]} (asks for your password)"
  sudo pacman -S --needed --noconfirm "${missing[@]}"
fi

# Rust: whatever cargo is on PATH, else mise (Omarchy ships it), else pacman.
if command -v cargo >/dev/null; then
  cargo=(cargo)
elif command -v mise >/dev/null; then
  say "Installing Rust with mise"
  mise install rust@latest >/dev/null 2>&1
  cargo=(mise exec rust@latest -- cargo)
else
  say "Installing Rust (asks for your password)"
  sudo pacman -S --needed --noconfirm rust
  cargo=(cargo)
fi

if [[ "$dir" != "$here" ]]; then
  if [[ -d "$dir/.git" ]]; then
    say "Updating $dir"
    git -C "$dir" pull --ff-only --quiet
  elif [[ -e "$dir" ]]; then
    fail "$dir exists but is not an Omamich checkout; move it away or set OMAMICH_DIR."
  else
    say "Downloading Omamich into $dir"
    git clone --quiet --depth 1 "$repo" "$dir"
  fi
fi

say "Building the backend (a few minutes the first time)"
make -C "$dir" --no-print-directory install CARGO="${cargo[*]}" >/dev/null

say "Linking the plugin into Omarchy"
"$dir/scripts/link-plugin.sh"

if $restart; then
  say "Restarting the Omarchy shell"
  omarchy restart shell >/dev/null 2>&1 || true
fi

cat <<EOF

Omamich is installed. Click the photos icon in the bar, then add your Immich
address and an API key (Immich: profile picture → Account Settings → API Keys).
$($restart || echo "Restart the shell first: omarchy restart shell")
Update later by running this installer again. Remove with:
  $dir/scripts/uninstall.sh
EOF
