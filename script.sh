#!/bin/zsh
# SSD Cleanup Scanner — fully dynamic scan, no hardcoded app lists
setopt NO_NOMATCH 2>/dev/null

HOME_DIR="$HOME"
OUTPUT="$HOME_DIR/Desktop/ssd-cleanup-report.html"

# ─── helpers ───────────────────────────────────────────────────────────────────

get_size_kb() {
  [[ ! -e "$1" ]] && echo 0 && return
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

get_size_mb() {
  local kb=$(get_size_kb "$1")
  echo "scale=2; ${kb:-0} / 1024" | bc 2>/dev/null || echo 0
}

get_mod_date() {
  [[ ! -e "$1" ]] && echo "N/A" && return
  stat -f "%Sm" -t "%Y-%m-%d" "$1" 2>/dev/null || echo "N/A"
}

age_days() {
  [[ ! -e "$1" ]] && echo 9999 && return
  local me=$(stat -f "%m" "$1" 2>/dev/null || echo 0)
  echo $(( ($(date +%s) - me) / 86400 ))
}

# ─── build installed app index ─────────────────────────────────────────────────
# Use mdfind + ls to build a comprehensive lowercase index of:
#   - app names (e.g. "firefox", "signal", "docker")
#   - bundle identifiers (e.g. "org.mozilla.firefox", "com.docker.docker")
# This is what we match Library dirs against — no hardcoding needed.

INSTALLED_INDEX_FILE=$(mktemp /tmp/ssd-installed.XXXXXX)
trap 'rm -f "$INSTALLED_INDEX_FILE"' EXIT

{
  # 1) All .app bundles found by Spotlight — names
  mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null | while read -r app; do
    basename "$app" .app
  done

  # 2) All .app bundles — bundle identifiers from Info.plist
  mdfind "kMDItemContentType == 'com.apple.application-bundle'" 2>/dev/null | while read -r app; do
    plist="$app/Contents/Info.plist"
    [[ -f "$plist" ]] && /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$plist" 2>/dev/null
  done

  # 3) Fallback: just ls /Applications and ~/Applications
  for d in /Applications/*.app ~/Applications/*.app(N); do
    basename "$d" .app 2>/dev/null
  done

  # 4) Running processes (catches menu-bar-only / agent apps)
  ps -eo comm= 2>/dev/null | xargs -I{} basename {} 2>/dev/null

} | tr '[:upper:]' '[:lower:]' | sort -u > "$INSTALLED_INDEX_FILE"

# Function: is this name related to any installed app?
# Matches directory name fragments against the installed index.
is_installed() {
  local raw="$1"
  local name=$(echo "$raw" | tr '[:upper:]' '[:lower:]')

  # Direct full match
  grep -qxF "$name" "$INSTALLED_INDEX_FILE" && return 0

  # Bundle-ID style: "com.foo.bar" — check if full ID is in index
  if [[ "$name" == *.* ]]; then
    grep -qF "$name" "$INSTALLED_INDEX_FILE" && return 0
    # Extract the last segment as readable name (e.g. "bar" from "com.foo.bar")
    local last="${name##*.}"
    [[ ${#last} -ge 3 ]] && grep -qxF "$last" "$INSTALLED_INDEX_FILE" && return 0
    # Also check if the index contains an entry starting with this bundle prefix
    local prefix="${name%.*}"
    grep -qF "$prefix" "$INSTALLED_INDEX_FILE" && return 0
  fi

  # Readable name matching: strip common suffixes/prefixes, check substrings
  # e.g. "Google Chrome Helper" → look for "chrome", "google chrome"
  local words=("${(@s/ /)name}")
  for w in "${words[@]}"; do
    [[ ${#w} -ge 4 ]] && grep -qF "$w" "$INSTALLED_INDEX_FILE" && return 0
  done

  # dash/underscore separated (e.g. "waveterm-updater" → "waveterm")
  local base="${name%%-*}"
  [[ "$base" != "$name" && ${#base} -ge 3 ]] && grep -qF "$base" "$INSTALLED_INDEX_FILE" && return 0

  return 1
}

# Derive a human-readable app name from a directory name
readable_name() {
  local raw="$1"
  # Bundle ID → last meaningful component
  if [[ "$raw" == *.* ]]; then
    local last="${raw##*.}"
    # If last segment is too short or generic, use second-to-last
    if [[ ${#last} -lt 3 || "$last" == "app" || "$last" == "macos" ]]; then
      local stripped="${raw%.*}"
      last="${stripped##*.}"
    fi
    echo "$last"
  else
    echo "$raw"
  fi
}

# ─── JSON accumulator ─────────────────────────────────────────────────────────

ITEMS="["
FIRST=true

add() {
  local name="$1" path="$2" size_mb="$3" date="$4" tag="$5" app="$6"
  [[ "$size_mb" == "0" || "$size_mb" == ".00" || "$size_mb" == "0.00" ]] && return
  (( $(echo "$size_mb < 0.005" | bc 2>/dev/null || echo 0) )) && return
  $FIRST && FIRST=false || ITEMS+=","
  name=${name//\"/\\\"}; path=${path//\"/\\\"}; app=${app//\"/\\\"}
  ITEMS+="{\"name\":\"$name\",\"path\":\"$path\",\"size\":$size_mb,\"date\":\"$date\",\"tag\":\"$tag\",\"app\":\"$app\"}"
}

# ─── notification ──────────────────────────────────────────────────────────────

osascript -e 'display notification "Scanning your SSD for cleanup candidates..." with title "SSD Cleanup" sound name "Submarine"' 2>/dev/null &

# ─── SCAN: ~/Library/Application Support ───────────────────────────────────────

for dir in "$HOME_DIR/Library/Application Support"/*(N/); do
  dirname="${dir:t}"
  # Always skip macOS system directories
  [[ "$dirname" == com.apple.* || "$dirname" == Apple ]] && continue
  [[ "$dirname" == CloudKit || "$dirname" == AddressBook || "$dirname" == CrashReporter ]] && continue
  [[ "$dirname" == Animoji || "$dirname" == AudioUnitCache ]] && continue

  if is_installed "$dirname"; then
    # App IS installed — skip (it's active data)
    continue
  fi

  # App NOT installed — it's a leftover
  sz=$(get_size_mb "$dir")
  dt=$(get_mod_date "$dir")
  rn=$(readable_name "$dirname")
  ad=$(age_days "$dir")

  if (( ad > 365 )); then
    add "$rn (App Support — stale)" "~/Library/Application Support/$dirname" "$sz" "$dt" "leftover" "$rn"
  else
    add "$rn (App Support)" "~/Library/Application Support/$dirname" "$sz" "$dt" "leftover" "$rn"
  fi
done

# ─── SCAN: ~/Library/Caches ───────────────────────────────────────────────────

for dir in "$HOME_DIR/Library/Caches"/*(N/); do
  dirname="${dir:t}"
  [[ "$dirname" == com.apple.* || "$dirname" == Metadata ]] && continue

  sz=$(get_size_mb "$dir")
  # Skip tiny caches (<1 MB)
  (( $(echo "$sz < 1" | bc 2>/dev/null || echo 0) )) && continue

  dt=$(get_mod_date "$dir")
  rn=$(readable_name "$dirname")

  if is_installed "$dirname"; then
    # App is installed — this is a clearable cache
    add "$rn (Cache)" "~/Library/Caches/$dirname" "$sz" "$dt" "cache" "$rn"
  else
    # App NOT installed — leftover cache
    add "$rn (Leftover Cache)" "~/Library/Caches/$dirname" "$sz" "$dt" "leftover" "$rn"
  fi
done

# ─── SCAN: ~/Library/Saved Application State ──────────────────────────────────

for dir in "$HOME_DIR/Library/Saved Application State"/*(N/); do
  dirname="${dir:t}"
  ad=$(age_days "$dir")

  sz=$(get_size_mb "$dir")
  dt=$(get_mod_date "$dir")
  rn=$(readable_name "${dirname%.savedState}")

  if ! is_installed "${dirname%.savedState}"; then
    add "$rn (Saved State — leftover)" "~/Library/Saved Application State/$dirname" "$sz" "$dt" "leftover" "$rn"
  elif (( ad > 365 )); then
    add "$rn (Saved State — stale)" "~/Library/Saved Application State/$dirname" "$sz" "$dt" "stale" "$rn"
  fi
done

# ─── SCAN: ~/Library/Logs ─────────────────────────────────────────────────────

for dir in "$HOME_DIR/Library/Logs"/*(N/); do
  dirname="${dir:t}"
  [[ "$dirname" == com.apple.* || "$dirname" == DiagnosticReports ]] && continue

  sz=$(get_size_mb "$dir")
  dt=$(get_mod_date "$dir")
  rn=$(readable_name "$dirname")

  if ! is_installed "$dirname"; then
    add "$rn (Logs — leftover)" "~/Library/Logs/$dirname" "$sz" "$dt" "leftover" "$rn"
  else
    ad=$(age_days "$dir")
    (( ad > 365 )) && add "$rn (Logs — stale)" "~/Library/Logs/$dirname" "$sz" "$dt" "stale" "$rn"
  fi
done

# ─── SCAN: ~/Library/Preferences (directories only) ───────────────────────────

for dir in "$HOME_DIR/Library/Preferences"/*(N/); do
  [[ ! -d "$dir" ]] && continue
  dirname="${dir:t}"
  if ! is_installed "$dirname"; then
    sz=$(get_size_mb "$dir")
    dt=$(get_mod_date "$dir")
    rn=$(readable_name "$dirname")
    add "$rn (Preferences — leftover)" "~/Library/Preferences/$dirname" "$sz" "$dt" "leftover" "$rn"
  fi
done

# ─── SCAN: ~/Library/Containers (non-Apple) ───────────────────────────────────

for dir in "$HOME_DIR/Library/Containers"/*(N/); do
  dirname="${dir:t}"
  [[ "$dirname" == com.apple.* ]] && continue

  if ! is_installed "$dirname"; then
    sz_kb=$(get_size_kb "$dir")
    # Only report if > 5 MB
    (( sz_kb < 5120 )) && continue
    sz=$(echo "scale=2; $sz_kb / 1024" | bc)
    dt=$(get_mod_date "$dir")
    rn=$(readable_name "$dirname")
    add "$rn (Container — leftover)" "~/Library/Containers/$dirname" "$sz" "$dt" "leftover" "$rn"
  fi
done

# ─── SCAN: ~/Library/Group Containers (non-Apple) ─────────────────────────────

for dir in "$HOME_DIR/Library/Group Containers"/*(N/); do
  dirname="${dir:t}"
  [[ "$dirname" == *.apple.* || "$dirname" == *.Apple.* ]] && continue

  if ! is_installed "$dirname"; then
    sz_kb=$(get_size_kb "$dir")
    (( sz_kb < 5120 )) && continue
    sz=$(echo "scale=2; $sz_kb / 1024" | bc)
    dt=$(get_mod_date "$dir")
    rn=$(readable_name "$dirname")
    add "$rn (Group Container — leftover)" "~/Library/Group Containers/$dirname" "$sz" "$dt" "leftover" "$rn"
  fi
done

# ─── SCAN: Dotfiles & home configs ────────────────────────────────────────────

# System/shell dotfiles to never flag
SKIP_DOTS=(.DS_Store .Trash .claude .claude.json .cursor .zsh_history .zsh_sessions
           .zshrc .zprofile .zshenv .bash_profile .bashrc .profile .gitconfig
           .ssh .config .docker .local .cache .npm .cargo .bun .expo .gemini
           .colima .ollama .oh-my-zsh .lesshst .CFUserTextEncoding)

for item in "$HOME_DIR"/.[^.]*(N); do
  name="${item:t}"
  # Skip system dotfiles
  skip=false
  for s in "${SKIP_DOTS[@]}"; do
    [[ "$name" == "$s"* ]] && { skip=true; break; }
  done
  $skip && continue

  sz=$(get_size_mb "$item")
  dt=$(get_mod_date "$item")
  ad=$(age_days "$item")

  # Try to determine if it belongs to an installed app
  # Strip leading dot for matching
  bare="${name#.}"
  if ! is_installed "$bare"; then
    if (( ad > 365 )); then
      add "$name (dotfile — leftover/stale)" "~/$name" "$sz" "$dt" "leftover" "$bare"
    else
      # Recently touched but app not found — still flag if large
      (( $(echo "$sz > 10" | bc 2>/dev/null || echo 0) )) && \
        add "$name (dotfile — orphaned)" "~/$name" "$sz" "$dt" "leftover" "$bare"
    fi
  else
    # App is installed but dotfile is very stale
    (( ad > 365 )) && (( $(echo "$sz > 5" | bc 2>/dev/null || echo 0) )) && \
      add "$name (dotfile — stale)" "~/$name" "$sz" "$dt" "stale" "$bare"
  fi
done

# ─── SCAN: npm/pip/Go/Yarn/Bun caches (explicit well-known dev caches) ───────

[[ -d "$HOME_DIR/.npm" ]] && {
  sz=$(get_size_mb "$HOME_DIR/.npm"); dt=$(get_mod_date "$HOME_DIR/.npm")
  add "npm cache" "~/.npm" "$sz" "$dt" "cache" "npm"
}
[[ -d "$HOME_DIR/.cache" ]] && {
  sz=$(get_size_mb "$HOME_DIR/.cache"); dt=$(get_mod_date "$HOME_DIR/.cache")
  add "User cache (~/.cache)" "~/.cache" "$sz" "$dt" "cache" "Various dev tools"
}

# ─── SCAN: Large files in Downloads ───────────────────────────────────────────

find "$HOME_DIR/Downloads" -maxdepth 2 -type f -size +50M 2>/dev/null | while read -r f; do
  sz=$(get_size_mb "$f")
  dt=$(get_mod_date "$f")
  fname="${f:t}"
  relpath="${f/#$HOME_DIR/~}"
  ext="${fname:e:l}"
  case "$ext" in
    mkv|mp4|avi|mov|wmv|m4v|webm) lbl="Video file" ;;
    dmg)       lbl="Disk image" ;;
    zip|tar|gz|bz2|xz|rar|7z|tgz) lbl="Archive" ;;
    iso|img)   lbl="Disk image" ;;
    pkg|mpkg)  lbl="Installer" ;;
    pdf)       lbl="PDF" ;;
    app)       lbl="Application" ;;
    *)         lbl="Large file" ;;
  esac
  add "$fname" "$relpath" "$sz" "$dt" "large" "$lbl"
done

# ─── SCAN: Old Downloads (any size, older than 1 year) ────────────────────────

find "$HOME_DIR/Downloads" -maxdepth 1 -type f -mtime +365 -size +1M -not -size +50M 2>/dev/null | while read -r f; do
  sz=$(get_size_mb "$f")
  dt=$(get_mod_date "$f")
  fname="${f:t}"
  relpath="${f/#$HOME_DIR/~}"
  add "$fname (old download)" "$relpath" "$sz" "$dt" "stale" "Old download"
done

# ─── SCAN: /usr/local leftovers ───────────────────────────────────────────────

for dir in /usr/local/*(N/); do
  dirname="${dir:t}"
  # Standard system dirs
  [[ "$dirname" == bin || "$dirname" == lib || "$dirname" == share || "$dirname" == include || "$dirname" == Homebrew || "$dirname" == cli-plugins || "$dirname" == etc || "$dirname" == var || "$dirname" == opt || "$dirname" == sbin || "$dirname" == man || "$dirname" == libexec ]] && continue
  sz=$(get_size_mb "$dir")
  dt=$(get_mod_date "$dir")
  if ! is_installed "$dirname"; then
    add "$dirname (/usr/local — leftover)" "/usr/local/$dirname" "$sz" "$dt" "leftover" "$dirname"
  fi
done

# ─── SCAN: Large home-level directories ──────────────────────────────────────

for dir in "$HOME_DIR"/*(N/); do
  dirname="${dir:t}"
  # Skip standard macOS dirs
  [[ "$dirname" == Library || "$dirname" == Desktop || "$dirname" == Documents || "$dirname" == Downloads ]] && continue
  [[ "$dirname" == Music || "$dirname" == Movies || "$dirname" == Pictures || "$dirname" == Public || "$dirname" == Applications ]] && continue

  sz_kb=$(get_size_kb "$dir")
  sz=$(echo "scale=2; $sz_kb / 1024" | bc)
  dt=$(get_mod_date "$dir")
  ad=$(age_days "$dir")

  count=$(ls -A "$dir" 2>/dev/null | wc -l | tr -d ' ')
  if (( count <= 1 )); then
    add "$dirname (empty/near-empty folder)" "~/$dirname" "0.01" "$dt" "stale" "$dirname"
  elif (( sz_kb > 102400 )); then  # > 100 MB
    if (( ad > 365 )); then
      add "$dirname (large & stale)" "~/$dirname" "$sz" "$dt" "stale" "$dirname"
    else
      add "$dirname (large folder)" "~/$dirname" "$sz" "$dt" "large" "$dirname"
    fi
  elif (( ad > 365 && sz_kb > 1024 )); then
    add "$dirname (stale folder)" "~/$dirname" "$sz" "$dt" "stale" "$dirname"
  fi
done

# ─── SCAN: Homebrew cleanup estimate ──────────────────────────────────────────

if command -v brew &>/dev/null; then
  cleanup_line=$(brew cleanup --dry-run 2>/dev/null | grep "free approximately" || true)
  if [[ -n "$cleanup_line" ]]; then
    cleanup_size=$(echo "$cleanup_line" | grep -oE '[0-9]+(\.[0-9]+)?' | head -1)
    cleanup_unit=$(echo "$cleanup_line" | grep -oE '(MB|GB)' | head -1)
    cleanup_mb="$cleanup_size"
    [[ "$cleanup_unit" == "GB" ]] && cleanup_mb=$(echo "$cleanup_size * 1024" | bc 2>/dev/null)
    [[ -n "$cleanup_mb" ]] && add "Homebrew old versions (run: brew cleanup)" "brew cleanup" "${cleanup_mb}" "N/A" "cache" "Homebrew"
  fi
fi

ITEMS+="]"

# ─── disk info ─────────────────────────────────────────────────────────────────

DISK_RAW=$(df -h / | awk 'NR==2 {print $2 "|" $3 "|" $4 "|" $5}')
DISK_TOTAL=$(echo "$DISK_RAW" | cut -d'|' -f1)
DISK_USED=$(echo "$DISK_RAW" | cut -d'|' -f2)
DISK_FREE=$(echo "$DISK_RAW" | cut -d'|' -f3)
DISK_PCT=$(echo "$DISK_RAW" | cut -d'|' -f4)
SCAN_DATE=$(date "+%b %d, %Y at %H:%M")
APP_COUNT=$(wc -l < "$INSTALLED_INDEX_FILE" | tr -d ' ')

# ─── generate HTML ─────────────────────────────────────────────────────────────

cat > "$OUTPUT" << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>SSD Cleanup Report</title>
<style>
:root{--bg:#0d1117;--card:#161b22;--border:#30363d;--text:#e6edf3;--dim:#8b949e;--accent:#58a6ff;--red:#f85149;--yellow:#d29922;--green:#3fb950;--purple:#bc8cff}
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'SF Pro Text',sans-serif;background:var(--bg);color:var(--text);line-height:1.5;padding:24px;max-width:1200px;margin:0 auto}
h1{font-size:28px;margin-bottom:4px}
.sub{color:var(--dim);margin-bottom:20px;font-size:14px}
.disk-wrap{margin-bottom:24px}
.disk-outer{background:var(--card);border:1px solid var(--border);border-radius:8px;height:28px;overflow:hidden;position:relative}
.disk-fill{height:100%;border-radius:8px 0 0 8px;transition:width .6s}
.disk-lbl{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;font-size:12px;font-weight:600}
.disk-meta{display:flex;justify-content:space-between;margin-top:6px;font-size:12px;color:var(--dim)}
.stats{display:flex;gap:14px;margin-bottom:24px;flex-wrap:wrap}
.stat{background:var(--card);border:1px solid var(--border);border-radius:12px;padding:14px 18px;flex:1;min-width:160px}
.stat .l{color:var(--dim);font-size:11px;text-transform:uppercase;letter-spacing:.5px}
.stat .v{font-size:26px;font-weight:700;margin-top:2px}
.stat .v.red{color:var(--red)}.stat .v.yel{color:var(--yellow)}.stat .v.grn{color:var(--green)}
.legend{display:flex;gap:16px;flex-wrap:wrap;margin-bottom:18px}
.legend-i{display:flex;align-items:center;gap:6px;font-size:12px;color:var(--dim)}
.legend-d{width:10px;height:10px;border-radius:3px}
.ctrls{display:flex;gap:10px;margin-bottom:18px;flex-wrap:wrap;align-items:center}
.fbtn{background:var(--card);border:1px solid var(--border);color:var(--text);padding:7px 15px;border-radius:8px;cursor:pointer;font-size:13px;transition:all .15s}
.fbtn:hover{border-color:var(--accent)}.fbtn.on{background:var(--accent);color:#000;border-color:var(--accent);font-weight:600}
.sinp{background:var(--card);border:1px solid var(--border);color:var(--text);padding:7px 15px;border-radius:8px;font-size:13px;width:220px;outline:none}
.sinp:focus{border-color:var(--accent)}.sinp::placeholder{color:var(--dim)}
.sbtn{background:none;border:1px solid var(--border);color:var(--dim);padding:7px 14px;border-radius:8px;font-size:12px;cursor:pointer;transition:all .15s}
.sbtn:hover{color:var(--text);border-color:var(--dim)}
.sec{margin-bottom:28px}
.sec-h{display:flex;justify-content:space-between;align-items:center;margin-bottom:10px;cursor:pointer;user-select:none}
.sec-h h2{font-size:17px;display:flex;align-items:center;gap:8px}
.badge{background:var(--border);color:var(--dim);padding:2px 10px;border-radius:12px;font-size:11px;font-weight:500}
.chev{transition:transform .2s;font-size:13px;color:var(--dim)}.chev.shut{transform:rotate(-90deg)}
.ilist{display:flex;flex-direction:column;gap:3px}
.itm{background:var(--card);border:1px solid var(--border);border-radius:8px;padding:10px 14px;display:grid;grid-template-columns:30px 1fr 90px 110px 62px;align-items:center;gap:10px;transition:all .15s}
.itm:hover{border-color:var(--accent)}.itm.sel{border-color:var(--red);background:rgba(248,81,73,.06)}
.itm input[type=checkbox]{width:17px;height:17px;cursor:pointer;accent-color:var(--red)}
.i-info{min-width:0}
.i-name{font-weight:500;font-size:13px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.i-path{color:var(--dim);font-size:11px;font-family:'SF Mono',monospace;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.i-sz{font-weight:600;text-align:right;font-size:13px}
.sz-l{color:var(--red)}.sz-m{color:var(--yellow)}.sz-s{color:var(--dim)}
.i-dt{color:var(--dim);font-size:11px;text-align:right}
.i-tag{font-size:10px;padding:2px 7px;border-radius:5px;text-align:center;font-weight:500;white-space:nowrap}
.t-leftover{background:rgba(248,81,73,.15);color:var(--red)}
.t-stale{background:rgba(210,153,34,.15);color:var(--yellow)}
.t-cache{background:rgba(188,140,255,.15);color:var(--purple)}
.t-large{background:rgba(88,166,255,.15);color:var(--accent)}
.abar{position:sticky;bottom:0;background:var(--card);border:1px solid var(--border);border-radius:12px;padding:14px 18px;display:flex;justify-content:space-between;align-items:center;margin-top:20px;box-shadow:0 -4px 24px rgba(0,0,0,.4)}
.abar .si{font-size:13px;color:var(--dim)}.abar .si strong{color:var(--red);font-size:17px}
.bcopy{background:var(--red);color:#fff;border:none;padding:9px 22px;border-radius:8px;font-size:13px;cursor:pointer;font-weight:600;transition:opacity .15s}
.bcopy:hover{opacity:.85}.bcopy:disabled{opacity:.4;cursor:default}
.toast{position:fixed;bottom:100px;left:50%;transform:translateX(-50%);background:var(--green);color:#000;padding:9px 22px;border-radius:8px;font-weight:600;font-size:13px;opacity:0;transition:opacity .3s;pointer-events:none;z-index:10}
.toast.show{opacity:1}
@media(max-width:700px){.itm{grid-template-columns:28px 1fr 70px 50px}.i-dt{display:none}.i-tag{display:none}}
</style>
</head>
<body>
<h1>SSD Cleanup Report</h1>
<p class="sub" id="subline"></p>
<div class="disk-wrap">
  <div class="disk-outer"><div class="disk-fill" id="diskFill"></div><div class="disk-lbl" id="diskLbl"></div></div>
  <div class="disk-meta"><span id="diskU"></span><span id="diskF"></span></div>
</div>
<div class="stats">
  <div class="stat"><div class="l">Total Reclaimable</div><div class="v red" id="totalSz">0</div></div>
  <div class="stat"><div class="l">Selected</div><div class="v yel" id="selSz">0 MB</div></div>
  <div class="stat"><div class="l">Items Found</div><div class="v" id="itmCt">0</div></div>
  <div class="stat"><div class="l">Leftover Apps</div><div class="v red" id="loCt">0</div></div>
</div>
<div class="legend">
  <div class="legend-i"><div class="legend-d" style="background:rgba(248,81,73,.5)"></div>Leftover from deleted app</div>
  <div class="legend-i"><div class="legend-d" style="background:rgba(210,153,34,.5)"></div>Stale (untouched 1+ year)</div>
  <div class="legend-i"><div class="legend-d" style="background:rgba(188,140,255,.5)"></div>Cache (safe to clear)</div>
  <div class="legend-i"><div class="legend-d" style="background:rgba(88,166,255,.5)"></div>Large file</div>
</div>
<div class="ctrls">
  <button class="fbtn on" data-f="all">All</button>
  <button class="fbtn" data-f="leftover">Leftover</button>
  <button class="fbtn" data-f="stale">Stale</button>
  <button class="fbtn" data-f="cache">Cache</button>
  <button class="fbtn" data-f="large">Large Files</button>
  <input type="text" class="sinp" placeholder="Search files..." id="si">
  <button class="sbtn" onclick="selAll()">Select All Visible</button>
  <button class="sbtn" onclick="deAll()">Deselect All</button>
  <button class="sbtn" onclick="sortTog()">Sort: <span id="sortLbl">Size</span></button>
</div>
<div id="secs"></div>
<div class="abar">
  <div class="si"><strong id="selCt">0</strong> items &mdash; <strong id="selTot">0 MB</strong> to free</div>
  <div style="display:flex;gap:8px">
    <button class="sbtn" onclick="cpPaths()">Copy Paths</button>
    <button class="bcopy" id="cmdBtn" onclick="cpCmd()" disabled>Copy Delete Commands</button>
  </div>
</div>
<div class="toast" id="toast"></div>
<script>
HTMLEOF

# Inject dynamic data
echo "const DATA=$ITEMS;" >> "$OUTPUT"
echo "const DISK={total:\"$DISK_TOTAL\",used:\"$DISK_USED\",free:\"$DISK_FREE\",pct:\"$DISK_PCT\",date:\"$SCAN_DATE\",apps:$APP_COUNT};" >> "$OUTPUT"

cat >> "$OUTPUT" << 'HTMLEOF2'
document.getElementById("subline").textContent=`Scanned ${DISK.date} — ${DISK.total} SSD, ${DISK.used} used, ${DISK.free} free — ${DISK.apps} installed apps indexed`;
const pn=parseInt(DISK.pct)||50,fl=document.getElementById("diskFill");
fl.style.width=pn+"%";fl.style.background=pn>85?"var(--red)":pn>60?"var(--yellow)":"var(--green)";
document.getElementById("diskLbl").textContent=DISK.pct+" used";
document.getElementById("diskU").textContent="Used: "+DISK.used+" of "+DISK.total;
document.getElementById("diskF").textContent="Free: "+DISK.free;
function fmt(m){return m>=1e3?(m/1e3).toFixed(1)+" GB":m>=1?m.toFixed(1)+" MB":(m*1e3).toFixed(0)+" KB"}
function szc(m){return m>=500?"sz-l":m>=50?"sz-m":"sz-s"}
const cats={leftover:{t:"Leftover App Data",i:[]},cache:{t:"Caches & Build Artifacts",i:[]},large:{t:"Large Files & Directories",i:[]},stale:{t:"Stale Files (1+ year untouched)",i:[]}};
DATA.forEach((d,i)=>{d.id=i;d.ck=false;d.mb=d.size;if(cats[d.tag])cats[d.tag].i.push(d)});
let filt="all",q="",srt="size";
function render(){
  const c=document.getElementById("secs");c.innerHTML="";
  let tMB=0,ic=0,lo=new Set;
  Object.entries(cats).forEach(([k,cat])=>{
    let its=cat.i.filter(i=>{if(filt!=="all"&&i.tag!==filt)return false;if(q){const ql=q.toLowerCase();return i.name.toLowerCase().includes(ql)||i.path.toLowerCase().includes(ql)||i.app.toLowerCase().includes(ql)}return true});
    if(!its.length)return;
    its.sort((a,b)=>srt==="size"?b.mb-a.mb:a.date.localeCompare(b.date));
    const cM=its.reduce((s,i)=>s+i.mb,0);tMB+=cM;ic+=its.length;
    if(k==="leftover")its.forEach(i=>lo.add(i.app));
    const sec=document.createElement("div");sec.className="sec";
    sec.innerHTML=`<div class="sec-h" onclick="togSec(this)"><h2><span class="chev">&#9660;</span>${cat.t}<span class="badge">${its.length} items — ${fmt(cM)}</span></h2></div><div class="ilist">${its.map(i=>`<div class="itm ${i.ck?'sel':''}" data-id="${i.id}"><input type=checkbox ${i.ck?'checked':''} onchange="tog(${i.id})"><div class="i-info"><div class="i-name" title="${esc(i.name)}">${esc(i.name)}</div><div class="i-path" title="${esc(i.path)}">${esc(i.path)}</div></div><div class="i-sz ${szc(i.mb)}">${fmt(i.mb)}</div><div class="i-dt">${i.date}</div><span class="i-tag t-${i.tag}">${i.tag}</span></div>`).join("")}</div>`;
    c.appendChild(sec)});
  document.getElementById("totalSz").textContent=fmt(tMB);
  document.getElementById("itmCt").textContent=ic;
  document.getElementById("loCt").textContent=lo.size;
  upSel()}
function esc(s){const d=document.createElement("div");d.textContent=s;return d.innerHTML}
function tog(id){DATA[id].ck=!DATA[id].ck;render()}
function togSec(h){const l=h.nextElementSibling,ch=h.querySelector(".chev");l.style.display=l.style.display==="none"?"":"none";ch.classList.toggle("shut")}
function upSel(){const s=DATA.filter(d=>d.ck),m=s.reduce((a,d)=>a+d.mb,0);document.getElementById("selCt").textContent=s.length;document.getElementById("selTot").textContent=fmt(m);document.getElementById("selSz").textContent=fmt(m);document.getElementById("cmdBtn").disabled=!s.length}
function selAll(){document.querySelectorAll(".itm").forEach(e=>{DATA[+e.dataset.id].ck=true});render()}
function deAll(){DATA.forEach(d=>d.ck=false);render()}
function sortTog(){srt=srt==="size"?"date":"size";document.getElementById("sortLbl").textContent=srt==="size"?"Size":"Date";render()}
function cpPaths(){const p=DATA.filter(d=>d.ck).map(d=>d.path.replace(/^~/,"$HOME")).join("\n");navigator.clipboard.writeText(p);showT("Paths copied!")}
function cpCmd(){const s=DATA.filter(d=>d.ck),l=["#!/bin/bash","# SSD Cleanup — "+new Date().toISOString().slice(0,10),"# REVIEW each line before running!",""];let brew=false;s.forEach(d=>{if(d.path.includes("brew cleanup")){brew=true;return}l.push('rm -rf "'+d.path.replace(/^~/,"$HOME")+'"')});if(brew)l.push("","brew cleanup");navigator.clipboard.writeText(l.join("\n"));showT("Delete commands copied!")}
function showT(m){const t=document.getElementById("toast");t.textContent=m;t.classList.add("show");setTimeout(()=>t.classList.remove("show"),2e3)}
document.querySelectorAll(".fbtn").forEach(b=>b.addEventListener("click",()=>{document.querySelectorAll(".fbtn").forEach(x=>x.classList.remove("on"));b.classList.add("on");filt=b.dataset.f;render()}));
document.getElementById("si").addEventListener("input",e=>{q=e.target.value;render()});
render();
</script></body></html>
HTMLEOF2

open "$OUTPUT"
osascript -e 'display notification "Report ready! Opening in browser..." with title "SSD Cleanup" sound name "Glass"' 2>/dev/null
