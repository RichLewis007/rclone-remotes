# rclone-remotes

Author: Rich Lewis - GitHub: RichLewis007

Interactive rclone remote browser with an easy to use TUI text-based menu user interface.

## Features

### Main Menu

- Lists all rclone remotes from `rclone listremotes`
- Shows cached Free/Total/Used space values next to each remote
- First remote (item #1) is selected by default
- Supports sorting by:
  - Name (alphabetical)
  - Free space (descending)
  - Drive size / Total space (descending)
  - Used space (descending)
- Menu structure:
  - Remote entries (numbered 1 through N)
  - Refresh remote list
  - Sort options (FREE, DRIVE, USED)
  - Quit (0)

### Remote Actions Menu

When you select a remote, you get an actions menu with:

- **Back to remote list** - Return to main menu
- **Get free space** - Run `rclone about` to get current space information
- **List dirs** - List top-level directories (`rclone lsd`)
- **Interactive size of all dirs** - Interactive size browser (`rclone ncdu`)
- **Run Tree on folder** - Display directory tree structure (`rclone tree`)
- **Empty trash** - Clean up trash/trash folders (`rclone cleanup`)
- **Remove GDrive duplicates** - Remove duplicate files on Google Drive (`rclone dedupe`)
- **Refresh expired rclone token** - Reconnect and refresh authentication (`rclone config reconnect`)
- **Mount drive read-only** - Mount remote as read-only filesystem
- **Quit** - Exit the program

## Caching System

The script uses a cache file to store space information for each remote, which significantly improves performance when you have many remotes.

### How It Works

1. **First Run**: When you first run the script, it starts a background process that queries each remote using `rclone about` and saves the results to a cache file.

2. **Subsequent Runs**: The script loads cached data immediately (for fast menu display) while the background updater refreshes the cache in the background.

3. **Cache File Format**: The cache file uses a simple pipe-delimited format:

   ```
   remote_name|Total_string|Used_string|Free_string
   ```

   Example:

   ```
   my-gdrive|10 TiB|2.357 TiB|2.0 TiB
   gemini-onedrive|1.005 TiB|917.600 GiB|111.4 GiB
   ```

### Cache File Location

- **Default**: `rclone-remotes.txt` in the script's directory
- **Custom**: Set the `REMOTE_DATA_FILE` environment variable to specify a different location

Example:

```bash
REMOTE_DATA_FILE=/path/to/custom/cache.txt ./rclone-remotes.sh
```

### Benefits

- **Fast Menu Display**: Menu appears instantly even with many remotes
- **Non-blocking**: Background updates don't delay menu interaction
- **Persistent**: Cache persists between script runs
- **Automatic Updates**: Cache refreshes automatically in the background

## Requirements

- `rclone` installed and configured with at least one remote
- `/utils/rclone-safemount.sh` (optional, only needed for mount functionality)

## UI Tool Support

The script supports multiple UI tools with automatic fallback:

1. **fzf** (preferred) - Fuzzy finder with search capability
2. **gum** (fallback) - Modern CLI tool for interactive prompts
3. **Basic select menu** (final fallback) - Built-in bash `select` menu

### Navigation Features (fzf)

- First item (item #1) is selected by default
- Circular/wrapping navigation: pressing up at the top wraps to the bottom, pressing down at the bottom wraps to the top
- Type-to-search filtering for quick navigation
- Arrow keys or vim-style (j/k) navigation

### Debug Mode

You can simulate different tool availability scenarios using environment variables:

```bash
# Simulate fzf not being found (will use gum or basic menu)
DEBUG_UI_NO_FZF=1 ./rclone-remotes.sh

# Simulate gum not being found (will use fzf or basic menu)
DEBUG_UI_NO_GUM=1 ./rclone-remotes.sh

# Simulate neither being found (will use basic menu only)
DEBUG_UI_NO_FZF=1 DEBUG_UI_NO_GUM=1 ./rclone-remotes.sh
```

## Environment Variables

The script supports the following environment variables for customization:

- **`REMOTE_DATA_FILE`** - Custom path for the cache file (default: `./rclone-remotes.txt`)

  ```bash
  REMOTE_DATA_FILE=/custom/path/cache.txt ./rclone-remotes.sh
  ```

- **`SAFEMOUNT_SCRIPT`** - Custom path to the mount script (default: `/utils/rclone-safemount.sh`)

  ```bash
  SAFEMOUNT_SCRIPT=/path/to/custom-mount.sh ./rclone-remotes.sh
  ```

- **`DEBUG_UI_NO_FZF`** - Debug flag to simulate fzf not being available
- **`DEBUG_UI_NO_GUM`** - Debug flag to simulate gum not being available

## Usage

Simply run the script:

```bash
./rclone-remotes.sh
```

Or make it executable and run from anywhere:

```bash
chmod +x rclone-remotes.sh
./rclone-remotes.sh
```

### Keyboard Navigation

**With fzf:**

- Arrow keys or `j`/`k` - Navigate up/down
- `Enter` - Select item
- `Esc` or `Ctrl+C` - Cancel/exit
- Type to filter/search items
- Up from top wraps to bottom, down from bottom wraps to top

**With gum:**

- Arrow keys - Navigate
- `Enter` - Select
- `Esc` or `Ctrl+C` - Cancel

**With basic menu:**

- Type number and press `Enter` to select
- Type `q` to quit

## File Structure

- `rclone-remotes.sh` - Main script
- `rclone-remotes.txt` - Cache file (created automatically, excluded from git, safe to delete)
- `.gitignore` - Excludes cache file from version control

## Author

Author: Rich Lewis - GitHub: RichLewis007
