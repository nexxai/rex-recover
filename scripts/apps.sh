#!/bin/sh
# Stage menu edits until explicit approval; the shared parser is the authority
# on valid names, just as it is for capture and recovery.
set -eu
umask 077
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/scripts/setup.sh"
reader="$root/bin/rex-recover-config"
config=$1
case "$config" in /*) ;; *) config="$PWD/$config" ;; esac
valid_path "$config"
"$reader" "$config" >/dev/null
stage=$(mktemp -d "${TMPDIR:-/tmp}/rex-recover-apps.XXXXXX")
trap 'rm -f "$stage/"*; rmdir "$stage"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cp "$config" "$stage/apps.conf"
cp "$stage/apps.conf" "$stage/original"

while :; do
  "$reader" "$stage/apps.conf" >"$stage/entries"
  printf '\nMonitored apps (%s):\n' "$config"
  if [ -s "$stage/entries" ]; then
    awk '{ printf "  %d) %s\n", NR, $0 }' "$stage/entries"
  else
    echo "  (none)"
  fi
  echo "  a) Add apps"
  echo "  r) Remove apps by number"
  echo "  s) Save and exit"
  echo "  q) Cancel without saving"
  ask "Choose an action: "
  case "$answer" in
    a|A)
      ask "Apps to add (spaces or commas): "
      printf '%s\n' "$answer" | tr ',[:space:]' '\n' | awk 'NF' >"$stage/input"
      if ! "$reader" "$stage/input" >"$stage/requested"; then
        echo "Enter bare executable names only; no changes made."
        continue
      fi
      : >"$stage/added"
      while IFS= read -r app; do
        if ! grep -Fxq "$app" "$stage/entries"; then
          printf '%s\n' "$app" >>"$stage/added"
        fi
      done <"$stage/requested"
      if [ ! -s "$stage/added" ]; then echo "No new apps to add."; continue; fi
      # Ensure an unterminated comment cannot swallow the first appended name.
      awk '1' "$stage/apps.conf" >"$stage/candidate"
      cat "$stage/added" >>"$stage/candidate"
      mv "$stage/candidate" "$stage/apps.conf"
      ;;
    r|R)
      if [ ! -s "$stage/entries" ]; then echo "No apps to remove."; continue; fi
      ask "Numbers to remove (spaces or commas): "
      printf '%s\n' "$answer" | tr ',[:space:]' '\n' | awk 'NF' >"$stage/requested"
      if ! LC_ALL=C awk -v count="$(wc -l <"$stage/entries")" '
        $0 !~ /^[0-9]+$/ || $0 < 1 || $0 > count {
          print "Choose numbers from the displayed list." > "/dev/stderr"
          exit 2
        }
        { printf "%d\n", $0 }
      ' "$stage/requested" >"$stage/numbers"; then continue; fi
      if [ ! -s "$stage/numbers" ]; then continue; fi
      : >"$stage/removed"
      while IFS= read -r number; do
        sed -n "${number}p" "$stage/entries" >>"$stage/removed"
      done <"$stage/numbers"
      # Match names using the parser's comment/CRLF rules while retaining the
      # original text of every unselected line.
      awk '
        FILENAME == ARGV[1] { removed[$0] = 1; next }
        {
          original = $0
          sub(/\r$/, "")
          sub(/#.*/, "")
          if (!($1 in removed)) print original
        }
      ' "$stage/removed" "$stage/apps.conf" >"$stage/candidate"
      mv "$stage/candidate" "$stage/apps.conf"
      ;;
    s|S)
      cmp -s "$config" "$stage/original" ||
        die "Config changed while the menu was open; reopen rex-recover apps and try again. No changes saved."
      copy_file "$stage/apps.conf" "$config" 600
      echo "Saved monitored apps."
      echo "Restart the watcher service: rex-recover service restart"
      echo "Open new Rex terminals or re-source capture; launch newly added apps once."
      exit 0
      ;;
    q|Q) echo "Cancelled; no configuration changes made."; exit 0 ;;
    *) echo "Choose a, r, s, or q." ;;
  esac
done
