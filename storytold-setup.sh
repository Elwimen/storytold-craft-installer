#!/usr/bin/env bash
#
# storytold-setup.sh
# -----------------------------------------------------------------------------
# Install Gear Lever (if needed) and add selected Storytold "*craft" apps as
# auto-updating AppImages. For each chosen app this script:
#   - downloads the latest Linux AppImage for your CPU arch from GitHub,
#   - verifies it against the release's SHA256SUMS.txt,
#   - integrates it into Gear Lever (menu entry + icon),
#   - configures a GitHub update source (so Gear Lever can auto-update it),
#   - adds "Visit Website" / "Source Code" actions to the launcher.
#
# Re-runnable: already-integrated apps are UPDATED in place, not duplicated.
#
# Requirements: bash, curl, python3 (flatpak is installed on demand).
# -----------------------------------------------------------------------------

set -uo pipefail

# ----------------------------- Config ----------------------------------------
APP_ID="it.mijorus.gearlever"
ORG="storytold"
HOMEPAGE="https://getartcraft.com"
APPDIR="${GEARLEVER_APPDIR:-$HOME/AppImages}"
ASSUME_YES=0

ARCH="$(uname -m)"
case "$ARCH" in
  x86_64|amd64)  GLARCH="x86_64"  ;;
  aarch64|arm64) GLARCH="aarch64" ;;
  *)             GLARCH="x86_64"  ;;
esac
FILE_GLOB="*linux-${GLARCH}.AppImage"

# Master catalog: repo|Display|Equivalent|LinuxAvailable
CATALOG=(
  "photocraft|PhotoCraft|Adobe Photoshop|yes"
  "filmcraft|FilmCraft|Adobe Premiere Pro|yes"
  "lightcraft|LightCraft|Adobe Lightroom|yes"
  "pdfcraft|PdfCraft|Adobe Acrobat|yes"
  "vectorcraft|VectorCraft|Adobe Illustrator|yes"
  "effectcraft|EffectCraft|Adobe After Effects|yes"
  "designcraft|DesignCraft|Adobe InDesign|yes"
  "wordcraft|WordCraft|Microsoft Word|yes"
  "cadcraft|CADCraft|AutoCAD|yes"
  "gridcraft|GridCraft|Microsoft Excel|yes"
  "deckcraft|DeckCraft|Microsoft PowerPoint|yes"
  "soundcraft|SoundCraft|Avid Pro Tools|no"
  "artcraft|ArtCraft|ArtCraft suite (no Linux build)|no"
)

# repo -> alternate integrated basename (for detecting existing installs)
declare -A ALIASES=( [pdfcraft]="printcraft" )

# --------------------------- Small helpers -----------------------------------
gl()   { flatpak run "$APP_ID" "$@"; }
say()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n'  "$*" >&2; }
err()  { printf '\033[1;31m[x]\033[0m %s\n'  "$*" >&2; }
have() { command -v "$1" >/dev/null 2>&1; }

confirm() {
  [[ "$ASSUME_YES" == 1 ]] && return 0   # --yes / unattended
  [[ -t 0 ]] || return 0                 # no terminal: assume yes
  local ans
  read -r -p "${1:-Continue?} [Y/n] " ans
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]]
}

# Snapshot of integrated AppImage paths (refreshed explicitly)
SNAPSHOT=""
refresh_snapshot() {
  SNAPSHOT="$(gl --list-installed 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if($i ~ /^\//) print $i}')"
}

# Echo installed path for a repo key (match by basename == key or alias), else fail
path_for() {
  local key="$1" p base
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    base="$(basename "$p")"; base="${base%.*}"; base="${base,,}"
    [[ "$base" == "$key" ]] && { echo "$p"; return 0; }
    [[ -n "${ALIASES[$key]:-}" && "$base" == "${ALIASES[$key]}" ]] && { echo "$p"; return 0; }
  done <<< "$SNAPSHOT"
  return 1
}

# --------------------- Ensure Gear Lever is present ---------------------------
ensure_gearlever() {
  if flatpak info "$APP_ID" >/dev/null 2>&1; then
    say "Gear Lever present ($(flatpak info "$APP_ID" 2>/dev/null | awk '/^ *Version:/{print $2}'))."
    return 0
  fi

  warn "Gear Lever ($APP_ID) is not installed."

  if ! have flatpak; then
    err "Flatpak itself is not installed."
    if have pacman; then
      confirm "Install flatpak now via pacman?" \
        && sudo pacman -S --needed flatpak \
        || { err "Cannot continue without flatpak."; exit 1; }
    else
      err "Install flatpak with your package manager (https://flatpak.org/setup/), then re-run."
      exit 1
    fi
  fi

  say "Ensuring Flathub remote is configured..."
  flatpak remote-add --if-not-exists flathub \
    https://flathub.org/repo/flathub.flatpakrepo || true

  confirm "Install Gear Lever from Flathub now?" \
    || { err "Gear Lever is required. Aborting."; exit 1; }
  flatpak install -y flathub "$APP_ID" || { err "Gear Lever install failed."; exit 1; }
  flatpak info "$APP_ID" >/dev/null 2>&1 || { err "Gear Lever still unavailable."; exit 1; }
  say "Gear Lever installed."
}

# ------------------- GitHub release lookup for a new app ---------------------
# Echo "<tag>\t<appimage_url>\t<appimage_name>\t<sums_url>" or fail
gh_latest_asset() {
  curl -s -m 30 "https://api.github.com/repos/$ORG/$1/releases/latest" \
  | GLOB="$FILE_GLOB" python3 -I -c '
import sys, os, json, fnmatch
glob=os.environ["GLOB"]
try: d=json.loads(sys.stdin.read(), strict=False)
except Exception: sys.exit(2)
if not isinstance(d,dict) or "assets" not in d: sys.exit(3)
tag=d.get("tag_name",""); app_url=app_name=sums=""
for a in d["assets"]:
    n=a["name"]
    if fnmatch.fnmatch(n, glob): app_url, app_name = a["browser_download_url"], n
    if n=="SHA256SUMS.txt": sums=a["browser_download_url"]
if not app_url: sys.exit(4)
print("\t".join([tag, app_url, app_name, sums]))
'
}

# Download + verify. Args: url name sums_url destdir. Echo dest path on success.
download_verify() {
  local url="$1" name="$2" sums="$3" dest="$4" out="$4/$2" exp act
  # NOTE: stdout is this function's return channel (the file path), so all
  # human-readable progress goes to stderr.
  curl -fL -m 600 -o "$out" "$url" || { err "  download failed: $name"; return 1; }
  if [[ -n "$sums" ]]; then
    exp="$(curl -fsL -m 60 "$sums" | grep -F "$name" | awk '{print $1}' | head -1)"
    act="$(sha256sum "$out" | awk '{print $1}')"
    if [[ -n "$exp" && "$exp" == "$act" ]]; then
      say "  checksum OK" >&2
    else
      err "  checksum MISMATCH (exp=$exp act=$act) — discarding"; rm -f "$out"; return 1
    fi
  else
    warn "  no SHA256SUMS.txt in release — skipped verification"
  fi
  chmod +x "$out"; echo "$out"
}

set_source() {
  gl --set-update-source "$1" --manager GithubUpdater \
     repo="$ORG/$2" repo_filename="$FILE_GLOB" allow_prereleases=0 >/dev/null 2>&1
}

# Add Website/Source launcher actions (best-effort; re-run to re-apply)
add_website_action() {
  local path="$1" repo="$2" appsdir="$HOME/.local/share/applications" desktop
  desktop="$(grep -rlF "$path" "$appsdir" 2>/dev/null | head -1)"
  [[ -z "$desktop" ]] && { warn "  no .desktop found; skipped website action"; return 0; }
  grep -q '^\[Desktop Action craftweb\]' "$desktop" && return 0

  if grep -q '^Actions=' "$desktop"; then
    sed -i 's/^Actions=\(.*\)$/Actions=\1craftweb;craftsrc;/' "$desktop"
  else
    sed -i '0,/^\[Desktop Entry\]/s//[Desktop Entry]\nActions=craftweb;craftsrc;/' "$desktop"
  fi
  cat >> "$desktop" <<EOF

[Desktop Action craftweb]
Name=Visit Website
Exec=xdg-open $HOMEPAGE

[Desktop Action craftsrc]
Name=Source Code
Exec=xdg-open https://github.com/$ORG/$repo
EOF
  say "  added Website/Source launcher actions"
}

# ------------------------------ Process one app ------------------------------
process_app() {
  local repo="$1" display="$2" existing
  say "$display  ($ORG/$repo)"

  if existing="$(path_for "$repo")"; then
    say "  already integrated: $existing"
    set_source "$existing" "$repo" && say "  GitHub update source set"
    if gl --update "$existing" -y 2>&1 | grep -q 'updated successfully'; then
      say "  updated to latest"
    else
      warn "  no update applied (already latest, app running, or API limit)"
    fi
    add_website_action "$existing" "$repo"
    return 0
  fi

  local meta tag url name sums
  meta="$(gh_latest_asset "$repo")" \
    || { err "  no $GLARCH AppImage in latest release — skipping"; return 1; }
  IFS=$'\t' read -r tag url name sums <<< "$meta"
  say "  latest: $tag  ($name)"

  local tmp file before after newpath
  tmp="$(mktemp -d)"
  file="$(download_verify "$url" "$name" "$sums" "$tmp")" || { rm -rf "$tmp"; return 1; }

  before="$(printf '%s\n' "$SNAPSHOT" | sort)"
  gl --integrate "$file" -y >/dev/null 2>&1
  refresh_snapshot
  after="$(printf '%s\n' "$SNAPSHOT" | sort)"
  rm -rf "$tmp"

  newpath="$(comm -13 <(echo "$before") <(echo "$after") | grep -m1 '/' || true)"
  [[ -z "$newpath" ]] && newpath="$(path_for "$repo" || true)"
  [[ -z "$newpath" ]] && { err "  integrated, but path not found; skipping config"; return 1; }

  say "  integrated: $newpath"
  set_source "$newpath" "$repo" && say "  GitHub update source set"
  add_website_action "$newpath" "$repo"
}

# ------------------------------ Selection UI ---------------------------------
select_apps() {   # prints chosen repo keys, one per line
  local -a keys=() labels=() avail=()
  local row k disp equiv av
  for row in "${CATALOG[@]}"; do
    IFS='|' read -r k disp equiv av <<< "$row"
    keys+=("$k"); labels+=("$disp — $equiv"); avail+=("$av")
  done

  if have whiptail; then
    local -a opts=(); local i on
    for i in "${!keys[@]}"; do
      [[ "${avail[$i]}" == "yes" ]] || continue
      on="OFF"; path_for "${keys[$i]}" >/dev/null 2>&1 && on="ON"
      opts+=("${keys[$i]}" "${labels[$i]}" "$on")
    done
    whiptail --title "Storytold Crafting Apps" \
      --checklist "Space = toggle, Enter = confirm.\n(* apps already installed are pre-checked)" \
      22 74 12 "${opts[@]}" 3>&1 1>&2 2>&3 | tr -d '"' | tr ' ' '\n'
  else
    local -a sel=(); local i n=1 mark line tok idx
    echo "Available Storytold apps:" >&2
    for i in "${!keys[@]}"; do
      [[ "${avail[$i]}" == "yes" ]] || continue
      sel+=("${keys[$i]}")
      mark=" "; path_for "${keys[$i]}" >/dev/null 2>&1 && mark="*"
      printf "  %2d) [%s] %-12s %s\n" "$n" "$mark" "${keys[$i]}" "${labels[$i]}" >&2
      n=$((n+1))
    done
    echo "  (* = already integrated)" >&2
    read -r -p "Enter numbers (e.g. 1 3 5), keys, or 'all': " line
    if [[ "$line" == "all" ]]; then printf '%s\n' "${sel[@]}"; return; fi
    for tok in $line; do
      if [[ "$tok" =~ ^[0-9]+$ ]]; then
        idx=$((tok-1))
        [[ $idx -ge 0 && $idx -lt ${#sel[@]} ]] && echo "${sel[$idx]}"
      else
        for k in "${sel[@]}"; do [[ "$k" == "$tok" ]] && echo "$k"; done
      fi
    done
  fi
}

# --------------------------- CLI / catalog helpers ---------------------------
usage() {
  cat <<EOF
Storytold crafting-apps installer

Usage: storytold-setup.sh [options] [app ...]

Options:
  --all            Install/update every app that has a Linux build
  --apps "a b c"   Non-interactive: install/update the named apps
  -y, --yes        Assume "yes" to prompts (unattended)
  --list           List the catalog and exit
  -h, --help       Show this help and exit

With no app arguments and no --all, an interactive menu is shown. Apps can also
be passed as plain arguments, e.g.:  storytold-setup.sh photocraft wordcraft

Env:
  GEARLEVER_APPDIR  Where integrated AppImages are stored (default ~/AppImages)
EOF
}

list_catalog() {
  local row k disp equiv av
  printf '%-13s %-28s %s\n' "KEY" "APP" "LINUX"
  for row in "${CATALOG[@]}"; do
    IFS='|' read -r k disp equiv av <<< "$row"
    printf '%-13s %-28s %s\n' "$k" "$disp" "$av"
  done
}

is_available() {   # key -> 0 if it has a Linux build
  local want="$1" row k disp equiv av
  for row in "${CATALOG[@]}"; do
    IFS='|' read -r k disp equiv av <<< "$row"
    [[ "$k" == "$want" ]] && { [[ "$av" == "yes" ]]; return; }
  done
  return 1
}

all_available_keys() {
  local row k disp equiv av
  for row in "${CATALOG[@]}"; do
    IFS='|' read -r k disp equiv av <<< "$row"
    [[ "$av" == "yes" ]] && echo "$k"
  done
}

# --------------------------------- Main --------------------------------------
main() {
  local MODE_ALL=0; local -a CLI_APPS=()
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h|--help) usage; exit 0 ;;
      --list)    list_catalog; exit 0 ;;
      --all)     MODE_ALL=1 ;;
      -y|--yes)  ASSUME_YES=1 ;;
      --apps)    shift; [[ $# -gt 0 ]] || { err "--apps needs a value"; exit 1; }
                 read -r -a CLI_APPS <<< "$1" ;;
      --)        shift; CLI_APPS+=("$@"); break ;;
      -*)        err "unknown option: $1"; usage; exit 1 ;;
      *)         CLI_APPS+=("$1") ;;
    esac
    shift
  done

  have curl    || { err "curl is required";    exit 1; }
  have python3 || { err "python3 is required"; exit 1; }
  mkdir -p "$APPDIR"

  ensure_gearlever
  refresh_snapshot

  local -a PICK=()
  if [[ $MODE_ALL -eq 1 ]]; then
    mapfile -t PICK < <(all_available_keys)
  elif [[ ${#CLI_APPS[@]} -gt 0 ]]; then
    local a
    for a in "${CLI_APPS[@]}"; do
      if is_available "$a"; then PICK+=("$a")
      else warn "skipping '$a' (unknown app or no Linux build)"; fi
    done
  else
    local -a SELECTED=(); local s
    mapfile -t SELECTED < <(select_apps)
    for s in "${SELECTED[@]}"; do [[ -n "$s" ]] && PICK+=("$s"); done
  fi

  [[ ${#PICK[@]} -eq 0 ]] && { warn "Nothing to do."; exit 0; }

  say "Selected: ${PICK[*]}"; echo
  local repo disp row k d e a
  for repo in "${PICK[@]}"; do
    disp="$repo"
    for row in "${CATALOG[@]}"; do
      IFS='|' read -r k d e a <<< "$row"; [[ "$k" == "$repo" ]] && disp="$d"
    done
    process_app "$repo" "$disp"
    echo
  done

  say "Done. Current status:"
  gl --list-installed 2>/dev/null

  cat <<EOF

Tips:
  Check updates:  flatpak run $APP_ID --list-updates
  Update one:     flatpak run $APP_ID --update ~/AppImages/<app>.appimage -y
  Website action: right-click the app's launcher icon (re-run this script if a
                  Gear Lever update ever clears it).
  Note: GitHub allows 60 unauthenticated API calls/hour; if you add many apps at
        once and hit the limit, wait ~1h and re-run (finished apps are skipped).
EOF
}

main "$@"
