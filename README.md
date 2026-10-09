# Storytold Crafting Apps — Installer

A single Bash script that installs [Gear Lever](https://github.com/mijorus/gearlever)
(if needed) and sets up the [Storytold](https://github.com/storytold) "**\*craft**"
suite — open-source, clean-room reimplementations of popular creative/office apps,
built in pure Rust — as **auto-updating AppImages** on Linux.

For each app you pick, the script:

- downloads the latest Linux AppImage for your CPU architecture from GitHub,
- verifies it against the release's `SHA256SUMS.txt`,
- integrates it into Gear Lever (application-menu entry + icon),
- configures a **GitHub update source** so Gear Lever can keep it up to date, and
- adds **Visit Website** / **Source Code** actions to the launcher (right-click).

It is **idempotent**: re-running updates already-installed apps in place instead of
creating duplicates.

## The apps

| App | Equivalent |
|-----|------------|
| PhotoCraft  | Adobe Photoshop |
| FilmCraft   | Adobe Premiere Pro |
| LightCraft  | Adobe Lightroom |
| PdfCraft    | Adobe Acrobat |
| VectorCraft | Adobe Illustrator |
| EffectCraft | Adobe After Effects |
| DesignCraft | Adobe InDesign |
| WordCraft   | Microsoft Word |
| CADCraft    | AutoCAD |
| GridCraft   | Microsoft Excel |
| DeckCraft   | Microsoft PowerPoint |

*SoundCraft (Avid Pro Tools) and ArtCraft are shown in the catalog but skipped —
they currently have no Linux AppImage release.*

> Equivalents are the projects' own stated comparisons, taken from their repository
> descriptions / READMEs.

## Requirements

- `bash`, `curl`, `python3`
- `flatpak` — if missing, the script offers to install it (via `pacman` on Arch/Manjaro)
- `whiptail` (optional) for the checkbox UI; a plain text menu is used otherwise

## Usage

```bash
git clone https://github.com/Elwimen/storytold-craft-installer.git
cd storytold-craft-installer
./storytold-setup.sh
```

Pick the apps you want in the menu and let it run. Run it again any time to add
more apps or pull the latest versions.

### Options via environment

- `GEARLEVER_APPDIR` — where integrated AppImages are stored (default `~/AppImages`).

## Updating later

Gear Lever handles updates once an app is integrated:

```bash
# see what has updates
flatpak run it.mijorus.gearlever --list-updates

# update one app (close it first if it is running)
flatpak run it.mijorus.gearlever --update ~/AppImages/<app>.appimage -y
```

## Notes & caveats

- **GitHub API limit:** unauthenticated requests are capped at 60/hour. Adding many
  apps at once can hit this; if so, wait ~1 hour and re-run (finished apps are skipped).
- **Launcher actions:** the Website/Source actions are appended to Gear Lever's
  generated `.desktop` file. A future Gear Lever update may regenerate that file and
  clear them — just re-run this script to re-apply.
- **Architecture:** `x86_64` and `aarch64` are auto-detected.

## How the GitHub update source is configured

Equivalent to selecting **Source → Github** in Gear Lever's UI, done via its CLI:

```bash
flatpak run it.mijorus.gearlever --set-update-source <appimage> \
  --manager GithubUpdater \
  repo=storytold/<app> \
  'repo_filename=*linux-<arch>.AppImage' \
  allow_prereleases=0
```

The `repo_filename` glob is matched whole-string with `fnmatch`, so it selects the
architecture-specific `*.AppImage` and excludes the `*.AppImage.zsync`, `.deb`,
`.rpm`, and `.tar.gz` assets.

## License

MIT — see [LICENSE](LICENSE).

## Disclaimer

This is an unofficial community helper and is not affiliated with Storytold /
ArtCraft or with the Gear Lever project. All trademarks belong to their respective
owners; product comparisons are the upstream projects' own descriptions.
