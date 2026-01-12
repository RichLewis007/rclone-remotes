#!/usr/bin/env bash
# rclone-remotes.sh
# Author: Rich Lewis - GitHub: RichLewis007
#
# Interactive rclone remote browser with text-based user interface
#
# MAIN MENU:
#   - Lists all rclone remotes from `rclone listremotes`
#   - Shows cached Free/Total/Used space values next to each remote
#   - First remote (item #1) is selected by default
#   - Supports sorting by: name, free space, drive size (total), or used space
#   - Menu items: Remotes (1..N), Refresh remote list, Sort options, Quit
#   - Select a remote to open its actions menu
#
# REMOTE ACTIONS MENU:
#   - Back to remote list
#   - Get free space - Run `rclone about REMOTE:` to get current space info
#   - List dirs - List top-level directories (`rclone lsd REMOTE:`)
#   - Interactive size of all dirs - Interactive size browser (`rclone ncdu REMOTE:`)
#   - Run Tree on folder - Display directory tree structure (`rclone tree REMOTE:DIR`)
#   - Empty trash - Clean up trash folders (`rclone cleanup REMOTE:`)
#   - Remove GDrive duplicates - Remove duplicate files (`rclone dedupe REMOTE:`)
#   - Refresh expired rclone token - Reconnect/refresh auth (`rclone config reconnect REMOTE:`)
#   - Mount drive read-only - Mount remote as read-only (`/utils/rclone-safemount.sh REMOTE: --read-only`)
#   - Quit - Exit the program
#
# CACHING SYSTEM:
#   The script uses a cache file (rclone-remotes.txt by default) to store space information
#   for each remote. This allows the menu to display quickly without waiting for
#   all `rclone about` calls to complete.
#
#   - First Run: Starts a background process that queries each remote using
#     `rclone about` and saves results to the cache file
#   - Subsequent Runs: Loads cached data immediately (fast menu display) while
#     the background updater refreshes the cache in the background
#   - Cache Format: Pipe-delimited: remote_name|Total_string|Used_string|Free_string
#   - Custom Location: Set REMOTE_DATA_FILE environment variable
#   - The cache file includes header comments explaining its purpose
#
# UI TOOL SUPPORT:
#   The script supports multiple UI tools with automatic fallback:
#   1. fzf (preferred) - Fuzzy finder with search, supports --reverse and --cycle
#   2. gum (fallback) - Modern CLI tool for interactive prompts
#   3. Basic select menu (final fallback) - Built-in bash `select` menu
#
#   Navigation features (fzf):
#   - First item selected by default
#   - Circular/wrapping navigation (up from top wraps to bottom, down from bottom wraps to top)
#   - Type-to-search filtering
#
# ENVIRONMENT VARIABLES:
#   REMOTE_DATA_FILE - Custom location for cache file (default: ./rclone-remotes.txt)
#   SAFEMOUNT_SCRIPT - Path to mount script (default: /utils/rclone-safemount.sh)
#   DEBUG_UI_NO_FZF - Set to 1 to simulate fzf not being found
#   DEBUG_UI_NO_GUM - Set to 1 to simulate gum not being found
#
# REQUIREMENTS:
#   - rclone installed and configured with at least one remote
#   - /utils/rclone-safemount.sh (optional, only needed for mount functionality)
#
# USAGE:
#   ./rclone-remotes.sh
#   DEBUG_UI_NO_FZF=1 ./rclone-remotes.sh  # Test with gum/basic menu only (no export needed)
#   export DEBUG_UI_NO_FZF=1; ./rclone-remotes.sh  # Alternative: export then run separately

set -euo pipefail

###############################################################################
# UI Functions (self-contained, no external dependencies)
###############################################################################

# Color constants
COLOR_RESET="\033[0m"
COLOR_BOLD="\033[1m"

# Logging functions
log_info() {
  echo "ℹ  $*" >&2
}

log_error() {
  echo "✗ ERROR: $*" >&2
}

log_warn() {
  echo "⚠  WARNING: $*" >&2
}

log_ok() {
  echo "✓ $*" >&2
}

# Pick option - interactive menu selection with fzf/gum/basic fallback
pick_option() {
  local prompt="$1"
  shift
  local items=("$@")
  
  if [[ ${#items[@]} -eq 0 ]]; then
    return 1
  fi
  
  # Split into header and prompt_line on first newline
  local header prompt_line
  header="${prompt%%$'\n'*}"
  if [[ "$prompt" == *$'\n'* ]]; then
    prompt_line="${prompt#*$'\n'}"
    # Remove any remaining newlines from prompt_line (keep only first line after header)
    prompt_line="${prompt_line%%$'\n'*}"
  else
    prompt_line="$prompt"
  fi
  
  # Try fzf first (best experience)
  if [[ "${DEBUG_UI_NO_FZF:-}" != "1" ]] && command -v fzf >/dev/null 2>&1; then
    local fzf_header="$header"
    local fzf_prompt="$prompt_line"
    if [[ -z "$fzf_prompt" ]]; then
      fzf_prompt="$fzf_header"
    fi
    
    # Calculate height based on terminal size and number of items
    local term_height
    term_height=$(tput lines 2>/dev/null || echo "24")
    local item_count=${#items[@]}
    # Calculate height: items + 3 lines for header/status/padding
    # This shows all items without large gaps
    local fzf_height=$((item_count + 3))
    # Cap at terminal height minus 1 to avoid overflow
    if [[ $fzf_height -gt $((term_height - 1)) ]]; then
      fzf_height=$((term_height - 1))
    fi
    # Ensure minimum height of 5
    if [[ $fzf_height -lt 5 ]]; then
      fzf_height=5
    fi
    
    printf '%s\n' "${items[@]}" | fzf \
      --header="$fzf_header" \
      --prompt="${fzf_prompt} " \
      --layout=reverse-list \
      --height="$fzf_height" \
      --cycle
    return $?
  fi
  
  # Try gum second (modern alternative)
  if [[ "${DEBUG_UI_NO_GUM:-}" != "1" ]] && command -v gum >/dev/null 2>&1; then
    # Calculate height based on terminal size (leave room for header and padding)
    local term_height
    term_height=$(tput lines 2>/dev/null || echo "24")
    local item_count=${#items[@]}
    # Use terminal height minus 4 (for header/padding), but at least 5, max term_height-2
    local gum_height=$((term_height - 4))
    if [[ $gum_height -lt 5 ]]; then
      gum_height=5
    fi
    if [[ $gum_height -gt $item_count ]]; then
      gum_height=$item_count
    fi
    
    printf '%s\n' "${items[@]}" | gum choose --header="$header" --height="$gum_height" --cursor=">"
    return $?
  fi
  
  # Fallback to basic select menu
  # Remove numbers from items since select adds its own numbers
  # But keep "0) Quit" items as-is and handle "0" input specially
  local select_items=()
  local quit_index=-1
  local item i=0
  for item in "${items[@]}"; do
    # Check if this is "0) Quit" or similar
    if [[ "$item" =~ ^[[:space:]]*0\)[[:space:]]+Quit ]]; then
      # Keep "0) Quit" as-is and remember its index
      select_items+=( "$item" )
      quit_index=$i
    else
      # Remove leading number and ") " pattern (e.g., " 1) " or "1) ")
      select_items+=( "${item#*[0-9]) }" )
    fi
    ((i++))
  done
  
  echo "$prompt" >&2
  echo "" >&2
  select choice in "${select_items[@]}"; do
    # Handle "0" input specially for Quit option
    if [[ "$REPLY" == "0" ]] && [[ $quit_index -ge 0 ]]; then
      echo "${items[$quit_index]}"
      return 0
    fi
    if [[ -n "$choice" ]]; then
      # Find the original item that matches this choice
      local i
      for ((i = 0; i < ${#select_items[@]}; i++)); do
        if [[ "${select_items[$i]}" == "$choice" ]]; then
          echo "${items[$i]}"
          return 0
        fi
      done
      # Fallback: return the choice as-is
      echo "$choice"
      return 0
    fi
  done
}

###############################################################################
# Script dir and data file
###############################################################################

# Directory where remotes.sh lives
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Persistent data file for rclone about info for all remotes
# Format: remote_name|Total_string|Used_string|Free_string
REMOTE_DATA_FILE="${REMOTE_DATA_FILE:-"$SCRIPT_DIR/rclone-remotes.txt"}"

###############################################################################
# Config
###############################################################################
SAFEMOUNT_SCRIPT="${SAFEMOUNT_SCRIPT:-/utils/rclone-safemount.sh}"

# Sort modes for main menu
# 0 = sort by NAME
# 1 = sort by FREE space
# 2 = sort by DRIVE size (Total)
# 3 = sort by USED space
SORT_MODE=0

# Parallel arrays holding cached about info (Bash 3 compatible)
# These arrays are indexed in parallel: ABOUT_REMOTE_NAMES[i] corresponds to
# ABOUT_TOTALS[i], ABOUT_USED_VALUES[i], and ABOUT_FREE_VALUES[i]
ABOUT_REMOTE_NAMES=()
ABOUT_TOTALS=()
ABOUT_USED_VALUES=()
ABOUT_FREE_VALUES=()

###############################################################################
# Helpers
###############################################################################

pause_any_key() {
  printf "Press any key to continue..."
  read -r -n 1 -s || true
  echo
}

require_rclone() {
  if ! command -v rclone >/dev/null 2>&1; then
    log_error "rclone not found in PATH."
    exit 1
  fi
}

# Convert a human-readable size string like "1.2 TiB" into an integer byte count
size_to_bytes() {
  local s="$1"
  if [[ -z "$s" ]]; then
    echo 0
    return
  fi

  local num unit
  num="${s%% *}"
  unit="${s#* }"
  unit="${unit%% *}"
  unit="${unit^^}"

  local factor=1
  case "$unit" in
    B|BYTE|BYTES) factor=1 ;;
    K|KB|KIB|KI|KIBYTE|KIBYTES) factor=$((1024)) ;;
    M|MB|MIB) factor=$((1024*1024)) ;;
    G|GB|GIB) factor=$((1024*1024*1024)) ;;
    T|TB|TIB) factor=$((1024*1024*1024*1024)) ;;
    P|PB|PIB) factor=$((1024*1024*1024*1024*1024)) ;;
    *) factor=1 ;;
  esac

  awk -v v="$num" -v f="$factor" 'BEGIN { printf "%.0f\n", v * f }'
}

# Find index of remote name in parallel arrays (returns -1 if not found)
find_remote_index() {
  local remote="$1"
  local i
  for ((i = 0; i < ${#ABOUT_REMOTE_NAMES[@]}; i++)); do
    if [[ "${ABOUT_REMOTE_NAMES[$i]}" == "$remote" ]]; then
      echo "$i"
      return 0
    fi
  done
  echo -1
  return 1
}

# Get cached total value for a remote (returns empty string if not found)
get_remote_total() {
  local remote="$1"
  local idx
  idx=$(find_remote_index "$remote")
  if [[ "$idx" -ge 0 ]] && [[ "$idx" -lt ${#ABOUT_TOTALS[@]} ]]; then
    echo "${ABOUT_TOTALS[$idx]}"
  fi
}

# Get cached used value for a remote (returns empty string if not found)
get_remote_used() {
  local remote="$1"
  local idx
  idx=$(find_remote_index "$remote")
  if [[ "$idx" -ge 0 ]] && [[ "$idx" -lt ${#ABOUT_USED_VALUES[@]} ]]; then
    echo "${ABOUT_USED_VALUES[$idx]}"
  fi
}

# Get cached free value for a remote (returns empty string if not found)
get_remote_free() {
  local remote="$1"
  local idx
  idx=$(find_remote_index "$remote")
  if [[ "$idx" -ge 0 ]] && [[ "$idx" -lt ${#ABOUT_FREE_VALUES[@]} ]]; then
    echo "${ABOUT_FREE_VALUES[$idx]}"
  fi
}

# Load remote data file into parallel arrays (Bash 3 compatible)
load_remote_data() {
  ABOUT_REMOTE_NAMES=()
  ABOUT_TOTALS=()
  ABOUT_USED_VALUES=()
  ABOUT_FREE_VALUES=()

  if [[ ! -f "$REMOTE_DATA_FILE" ]]; then
    return 0
  fi

  while IFS='|' read -r name total used free; do
    # Skip empty lines and comment lines (starting with #)
    [[ -n "$name" ]] || continue
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    ABOUT_REMOTE_NAMES+=("$name")
    ABOUT_TOTALS+=("$total")
    ABOUT_USED_VALUES+=("$used")
    ABOUT_FREE_VALUES+=("$free")
  done < "$REMOTE_DATA_FILE"
}

# Background updater: run rclone about for each remote and update the data file
update_remote_data() {
  local remotes=("$@")
  [[ "${#remotes[@]}" -gt 0 ]] || return 0

  mkdir -p "$(dirname "$REMOTE_DATA_FILE")" 2>/dev/null || true
  local tmp="${REMOTE_DATA_FILE}.tmp"
  : > "$tmp"

  # Add header comment explaining the file
  printf '# Cache file for rclone-remotes.sh\n' >> "$tmp"
  printf '# This file stores cached space information for rclone remotes.\n' >> "$tmp"
  printf '# It is safe to delete this file - it will be recreated on the next program run.\n' >> "$tmp"
  printf '# Format: remote_name|Total_string|Used_string|Free_string\n' >> "$tmp"

  local remote about_output total used free free_raw num remainder truncated_num

  for remote in "${remotes[@]}"; do
    about_output="$(rclone about "${remote}:" 2>/dev/null || true)"
    [[ -n "$about_output" ]] || continue

    total="$(printf '%s\n' "$about_output" | awk -F'Total:' '/Total:/ {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    used="$(printf '%s\n' "$about_output" | awk -F'Used:'  '/Used:/  {gsub(/^[ \t]+/, "", $2); print $2; exit}')"
    free_raw="$(printf '%s\n' "$about_output" | awk -F'Free:'  '/Free:/  {gsub(/^[ \t]+/, "", $2); print $2; exit}')"

    # Truncate numeric portion of free_raw to 1 decimal place (no rounding)
    if [[ -n "$free_raw" ]]; then
      if [[ "$free_raw" == *" "* ]]; then
        num="${free_raw%% *}"
        remainder="${free_raw#* }"
      else
        num="$free_raw"
        remainder=""
      fi
      truncated_num="$(awk -v v="$num" 'BEGIN { v = int(v*10)/10; printf "%.1f", v }')"
      if [[ -n "$remainder" ]]; then
        free="${truncated_num} ${remainder}"
      else
        free="${truncated_num}"
      fi
    else
      free=""
    fi

    printf '%s|%s|%s|%s\n' "$remote" "$total" "$used" "$free" >> "$tmp"
  done

  mv "$tmp" "$REMOTE_DATA_FILE"
}

###############################################################################
# Actions for a single remote
###############################################################################

action_get_free_space() {
  local remote="$1"
  log_info "Free space for remote: ${remote}:"
  echo
  if ! rclone about "${remote}:"; then
    echo
    log_error "rclone about failed for ${remote}:"
  fi
  echo
  pause_any_key
}

action_list_dirs() {
  local remote="$1"
  log_info "Top-level directories on remote: ${remote}:"
  echo
  if ! rclone lsd "${remote}:"; then
    echo
    log_error "rclone lsd failed for ${remote}:"
  fi
  echo
  pause_any_key
}

action_ncdu() {
  local remote="$1"
  log_info "Interactive size (ncdu) for remote: ${remote}:"
  echo
  log_warn "Launching 'rclone ncdu ${remote}:' (quit ncdu to return to menu)."
  echo
  if ! rclone ncdu "${remote}:"; then
    echo
    log_error "rclone ncdu failed for ${remote}:"
  fi
  echo
  pause_any_key
}

action_tree_on_folder() {
  local remote="$1"

  log_info "Run rclone tree on a top-level folder of remote: ${remote}:"
  echo
  log_info "Fetching top-level directories from ${remote}: ..."

  dirs=()
  while IFS= read -r line; do
    [[ -n "$line" ]] && dirs+=("$line")
  done < <(rclone lsd "${remote}:" 2>/dev/null | awk '{print $NF}')

  if [[ "${#dirs[@]}" -eq 0 ]]; then
    log_warn "No top-level directories found on ${remote}:."
    echo
    pause_any_key
    return
  fi

  local prompt_header="[REMOTE: ${remote}]"
  local prompt_body="Choose directory for rclone tree"

  local choice
  choice=$(pick_option "${prompt_header}"$'\n'"${prompt_body}" "${dirs[@]}") || {
    log_warn "Directory selection cancelled."
    echo
    pause_any_key
    return
  }

  local sel="$choice"

  echo
  log_info "Running: rclone tree -d --level 3 ${remote}:${sel}"
  echo

  if ! rclone tree -d --level 3 "${remote}:${sel}" | less; then
    echo
    log_error "rclone tree failed for ${remote}:${sel}"
  fi

  echo
  pause_any_key
}

action_cleanup() {
  local remote="$1"
  log_info "Empty trash / cleanup for remote: ${remote}:"
  echo
  log_warn "Running 'rclone cleanup ${remote}:'"
  echo
  if ! rclone cleanup "${remote}:"; then
    echo
    log_error "rclone cleanup failed for ${remote}:"
  fi
  echo
  pause_any_key
}

action_dedupe() {
  local remote="$1"
  log_info "Remove Google Drive duplicates for remote: ${remote}:"
  echo
  
  # Check if remote is a Google Drive
  local remote_type
  remote_type=$(rclone config show "$remote" 2>/dev/null | awk '/^type = / {print $3; exit}')
  
  if [[ "$remote_type" != "drive" ]]; then
    log_error "This cloud drive type cannot have duplicate names in the same folder."
    log_error "The dedupe operation is only available for Google Drive remotes."
    echo
    pause_any_key
    return 1
  fi
  
  log_warn "Running 'rclone dedupe ${remote}:'"
  log_warn "This may modify or remove duplicate files depending on dedupe mode."
  echo
  if ! rclone dedupe "${remote}:"; then
    echo
    log_error "rclone dedupe failed for ${remote}:"
  fi
  echo
  pause_any_key
}

action_refresh_token() {
  local remote="$1"
  log_info "Refresh expired rclone token for remote: ${remote}:"
  echo
  log_warn "Running 'rclone config reconnect ${remote}:'"
  echo
  if ! rclone config reconnect "${remote}:"; then
    echo
    log_error "rclone config reconnect failed for ${remote}:"
  fi
  echo
  pause_any_key
}

action_mount_read_only() {
  local remote="$1"
  log_info "Mount remote read-only: ${remote}:"
  echo

  if [[ ! -x "$SAFEMOUNT_SCRIPT" ]]; then
    log_error "Mount script '$SAFEMOUNT_SCRIPT' not found or not executable."
    echo
    pause_any_key
    return
  fi

  log_info "Running: $SAFEMOUNT_SCRIPT ${remote}: --read-only"
  echo
  if ! "$SAFEMOUNT_SCRIPT" "${remote}:" --read-only; then
    echo
    log_error "Mount script failed for ${remote}:"
  fi
  echo
  pause_any_key
}

###############################################################################
# Remote submenu (per remote)
###############################################################################

remote_menu() {
  local remote="$1"

  while true; do
    echo
    printf "%bRemote: %s:%b\n" "$COLOR_BOLD" "$remote" "$COLOR_RESET"
    echo

    local base_options=(
      "Back to remote list"
      "Get free space (rclone about)"
      "List dirs (rclone lsd)"
      "Interactive size of all dirs (rclone ncdu)"
      "Run Tree on folder (rclone tree)"
      "Empty trash (rclone cleanup)"
      "Remove GDrive duplicates (rclone dedupe)"
      "Refresh expired rclone token (rclone config reconnect)"
      "Mount drive read-only (/utils/rclone-safemount.sh)"
      "Quit"
    )

    # Build display_options in display order (first item will be selected by default)
    local display_options=()
    local total="${#base_options[@]}"
    
    # Add options in order (first item first)
    local i
    for ((i = 0; i < total - 1; i++)); do
      local num=$((i + 1))
      display_options+=( "${num}) ${base_options[$i]}" )
    done
    # Add Quit last
    display_options+=( "0) ${base_options[$((total - 1))]}" )

    local prompt_header="[REMOTE: ${remote}]"
    local prompt_body="Select action"

    local choice
    choice=$(pick_option "${prompt_header}"$'\n'"${prompt_body}" "${display_options[@]}") || {
      log_warn "Action selection cancelled for ${remote}, returning to remote list."
      return
    }

    local label="${choice#*) }"

    case "$label" in
      "Back to remote list")
        log_info "Returning to remote list."
        return
        ;;
      "Get free space (rclone about)")
        action_get_free_space "$remote"
        ;;
      "List dirs (rclone lsd)")
        action_list_dirs "$remote"
        ;;
      "Interactive size of all dirs (rclone ncdu)")
        action_ncdu "$remote"
        ;;
      "Run Tree on folder (rclone tree)")
        action_tree_on_folder "$remote"
        ;;
      "Empty trash (rclone cleanup)")
        action_cleanup "$remote"
        ;;
      "Remove GDrive duplicates (rclone dedupe)")
        action_dedupe "$remote"
        ;;
      "Refresh expired rclone token (rclone config reconnect)")
        action_refresh_token "$remote"
        ;;
      "Mount drive read-only (/utils/rclone-safemount.sh)")
        action_mount_read_only "$remote"
        ;;
      "Quit")
        log_ok "Goodbye."
        exit 0
        ;;
      *)
        log_warn "Unknown choice: $label"
        ;;
    esac
  done
}

###############################################################################
# Main remote selection loop
###############################################################################

main() {
  require_rclone

  local first_run=1

  while true; do
    # Load cached about data (from previous runs or background updates)
    load_remote_data

    remotes_raw=()
    while IFS= read -r line; do
      [[ -n "$line" ]] && remotes_raw+=("$line")
    done < <(rclone listremotes 2>/dev/null || true)

    if [[ "${#remotes_raw[@]}" -eq 0 ]]; then
      log_warn "No rclone remotes found."
      echo
      pause_any_key
      log_ok "Exiting."
      exit 0
    fi

    local unsorted=()
    local r
    for r in "${remotes_raw[@]}"; do
      unsorted+=( "${r%:}" )
    done

    local remotes=()

    if (( SORT_MODE == 0 )); then
      # Sort by name
      if ((${#unsorted[@]} > 0)); then
        IFS=$'\n' remotes=($(printf '%s\n' "${unsorted[@]}" | sort)) || remotes=("${unsorted[@]}")
      fi
    else
      # Sort by FREE / TOTAL / USED (descending)
      if ((${#unsorted[@]} > 0)); then
        remotes=()
        while IFS= read -r line; do
          [[ -n "$line" ]] && remotes+=("$line")
        done < <(
          for remote in "${unsorted[@]}"; do
            val_str=""
            case "$SORT_MODE" in
              1) val_str="$(get_remote_free "$remote")"  ;; # FREE
              2) val_str="$(get_remote_total "$remote")" ;; # DRIVE (Total)
              3) val_str="$(get_remote_used "$remote")"  ;; # USED
              *) val_str="$(get_remote_free "$remote")"  ;;
            esac
            bytes="$(size_to_bytes "$val_str")"
            printf '%016d %s\n' "$bytes" "$remote"
          done | sort -nr | awk '{ $1=""; sub(/^ /,""); print }'
        )
      fi
    fi

    # First run: start background updater to refresh rclone-remotes.txt
    if (( first_run )); then
      update_remote_data "${remotes[@]}" &
      first_run=0
    fi

    # Compute widest remote name for alignment
    local max_name_len=0
    local remote
    for remote in "${remotes[@]}"; do
      local len=${#remote}
      (( len > max_name_len )) && max_name_len=$len
    done
    local name_col_width=$((max_name_len + 2))

    # Build main menu entries in display order (top to bottom)
    # Order: Remotes (1..N), Refresh (N+1), Sort options (N+2..N+4), Quit (0)
    local menu_entries=()
    local remote_count=${#remotes[@]}
    
    # Add remotes first (item #1 will be selected by default)
    local info_label info_str info_display
    local r_idx display_num
    for ((r_idx = 0; r_idx < remote_count; r_idx++)); do
      local remote="${remotes[$r_idx]}"
      display_num=$((r_idx + 1))  # Number from 1 to remote_count
      
      case "$SORT_MODE" in
        2)
          info_label="Total"
          info_str="$(get_remote_total "$remote")"
          ;;
        3)
          info_label="Used"
          info_str="$(get_remote_used "$remote")"
          ;;
        *)
          info_label="Free"
          info_str="$(get_remote_free "$remote")"
          ;;
      esac

      if [[ -n "$info_str" ]]; then
        info_display="[$info_label: ${info_str}]"
      else
        info_display=""
      fi

      menu_entries+=( "$(printf '%2d) %-*s %s' "$display_num" "$name_col_width" "$remote" "$info_display")" )
    done
    
    # Calculate indices for remotes (they're at the start of the array)
    local first_remote_index=0
    local refresh_index=$remote_count
    
    # Add Refresh
    menu_entries+=( "$(printf '%2d) %s' $((remote_count + 1)) "REFRESH remotes list")" )
    
    # Add sort options
    local sort_free_index=$((remote_count + 1))
    menu_entries+=( "$(printf '%2d) %s' $((remote_count + 2)) "Sort by FREE space")" )
    
    local sort_total_index=$((remote_count + 2))
    menu_entries+=( "$(printf '%2d) %s' $((remote_count + 3)) "Sort by DRIVE size")" )
    
    local sort_used_index=$((remote_count + 3))
    menu_entries+=( "$(printf '%2d) %s' $((remote_count + 4)) "Sort by USED space")" )
    
    # Add Quit last (at bottom)
    local quit_index=$((remote_count + 4))
    menu_entries+=( "0) Quit" )

    # Build sort status label for the picker title
    local sort_label
    case "$SORT_MODE" in
      0) sort_label="NAME"  ;;
      1) sort_label="FREE space"  ;;
      2) sort_label="DRIVE" ;;
      3) sort_label="USED size"  ;;
      *) sort_label="NAME"  ;;
    esac

    # Title shown inside pick_option, so it survives any screen clearing
    local menu_title=$'rclone remotes\n[Sort: '"$sort_label"$']\n\nSelect a remote'

    local choice
    choice=$(pick_option "$menu_title" "${menu_entries[@]}") || {
      log_warn "Remote selection cancelled. Exiting."
      exit 0
    }

    # Determine which entry was selected
    local chosen_index=-1
    local i
    for ((i = 0; i < ${#menu_entries[@]}; i++)); do
      if [[ "${menu_entries[$i]}" == "$choice" ]]; then
        chosen_index=$i
        break
      fi
    done

    if (( chosen_index < 0 )); then
      log_warn "Unknown selection, exiting."
      exit 1
    fi

    if (( chosen_index >= first_remote_index && chosen_index < first_remote_index + remote_count )); then
      # Chose a remote - index matches directly
      local selected_remote_index=$((chosen_index - first_remote_index))
      local selected_remote="${remotes[$selected_remote_index]}"
      remote_menu "$selected_remote"
    elif (( chosen_index == refresh_index )); then
      log_info "Refreshing remote list..."
      continue
    elif (( chosen_index == sort_free_index )); then
      SORT_MODE=1
      log_info "Sorting remote menu by FREE space."
      continue
    elif (( chosen_index == sort_total_index )); then
      SORT_MODE=2
      log_info "Sorting remote menu by DRIVE size."
      continue
    elif (( chosen_index == sort_used_index )); then
      SORT_MODE=3
      log_info "Sorting remote menu by USED space."
      continue
    elif (( chosen_index == quit_index )); then
      log_ok "Goodbye."
      exit 0
    else
      log_warn "Unexpected menu index, exiting."
      exit 1
    fi
  done
}

main "$@"
