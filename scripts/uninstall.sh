#!/usr/bin/env bash
# Remove Omamich from Omarchy. Your photos are untouched; they live in Immich.
#
#   scripts/uninstall.sh          keep settings, the sync index and the cache
#   scripts/uninstall.sh --purge  also delete those, and the API key
set -euo pipefail

purge=false
[[ "${1:-}" == "--purge" ]] && purge=true

project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
config="${XDG_CONFIG_HOME:-$HOME/.config}"
data="${XDG_DATA_HOME:-$HOME/.local/share}"
cache="${XDG_CACHE_HOME:-$HOME/.cache}"

if command -v omarchy >/dev/null; then
  omarchy plugin disable dpetrariu.omamich >/dev/null 2>&1 || true
  omarchy plugin disable omamich >/dev/null 2>&1 || true
fi
# Only remove a plugin entry if it is a link (what install.sh makes), never a real folder.
# "omamich" is the id this plugin had before "dpetrariu.omamich".
for link in "$config/omarchy/plugins/dpetrariu.omamich" "$config/omarchy/plugins/omamich"; do
  if [[ -L "$link" ]]; then
    rm "$link"
  fi
done
rm -f "$data/applications/omamich.desktop" "$data/applications/omamich-upload.desktop"
rm -f "$data/icons/hicolor/scalable/apps/omamich.svg"
update-desktop-database "$data/applications" 2>/dev/null || true
command -v omarchy-shell >/dev/null && omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

if $purge; then
  for folder in "$config/omamich" "$data/omamich" "$cache/omamich"; do
    # Never the code itself, wherever it was cloned.
    [[ "$(readlink -f "$folder")" == "$project_dir" ]] && continue
    rm -rf "$folder"
  done
  if command -v secret-tool >/dev/null; then
    secret-tool clear service omamich account api_key 2>/dev/null || true
  fi
  echo "Removed Omamich, its settings, sync index, cache and saved API key."
else
  echo "Removed Omamich from Omarchy. Settings are kept in $config/omamich; run with --purge to delete them."
fi
echo "The code is still in $project_dir; delete that folder too if you like."
echo "Restart the shell to finish: omarchy restart shell"
