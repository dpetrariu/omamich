#!/usr/bin/env bash
# Link this checkout into Omarchy's plugin folder and enable it.
set -euo pipefail
project_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
plugin_home="${XDG_CONFIG_HOME:-$HOME/.config}/omarchy/plugins"
install_path="$plugin_home/omamich"

command -v omarchy >/dev/null || { echo "omarchy is required" >&2; exit 1; }
[[ -x "$project_dir/bin/omamich" ]] || { echo "Build the backend first: make install" >&2; exit 1; }

omarchy plugin validate "$project_dir"
mkdir -p "$plugin_home"
if [[ -L "$install_path" && "$(readlink -f "$install_path")" == "$project_dir" ]]; then
  :
elif [[ -e "$install_path" || -L "$install_path" ]]; then
  echo "$install_path already exists and is not this checkout; move it away first" >&2
  exit 1
else
  ln -s "$project_dir" "$install_path"
fi
apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications"
mkdir -p "$apps"
install -m 644 "$project_dir/setup/omamich.desktop" "$apps/omamich.desktop"
# NoDisplay and no default handler: it only adds an "Open with" choice.
sed "s|OMAMICH_DIR|$project_dir|" "$project_dir/setup/omamich-upload.desktop" > "$apps/omamich-upload.desktop"
# The launcher icon, by name, from the user icon theme.
icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/scalable/apps"
mkdir -p "$icons"
install -m 644 "$project_dir/ui/assets/icon.svg" "$icons/omamich.svg"
gtk-update-icon-cache -q -t "${icons%/scalable/apps}" 2>/dev/null || true
update-desktop-database "$apps" 2>/dev/null || true
omarchy-shell shell rescanPlugins
# The rescan finishes after the call returns; until then enable reports the plugin unknown.
for try in {1..20}; do
  omarchy plugin enable omamich 2>/dev/null && break
  (( try < 20 )) || omarchy plugin enable omamich
  sleep 0.5
done
echo "Omamich is linked at $install_path. Click the photos icon in the bar."
