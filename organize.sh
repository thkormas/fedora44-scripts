#!/bin/sh
# organize.sh - group files in a directory into category folders.
#
# Usage:
#   organize.sh scan  [options] <dir>
#   organize.sh move  [options] <dir>
#   organize.sh undo  <manifest>
#   organize.sh help
#
# Options:
#   -m, --manifest <file>   manifest path (default: <dir>/.organize-manifest)
#   -q, --quiet             only print errors
#
# 'scan' shows what 'move' would do. 'undo' restores every file recorded in a
# manifest produced by 'move', so the operation is always reversible.

set -u

PROG=$(basename "$0")
VERSION="1.0.0"

MANIFEST=""
QUIET=0

info() {
	[ "$QUIET" -eq 1 ] && return 0
	printf '%s\n' "$*"
}

warn() {
	printf '%s: %s\n' "$PROG" "$*" >&2
}

die() {
	warn "$*"
	exit 1
}

usage() {
	cat <<EOF
$PROG $VERSION - group files into category folders

Usage:
  $PROG scan [options] <dir>     preview the grouping (nothing is changed)
  $PROG move [options] <dir>     move files into category folders
  $PROG undo <manifest>          restore every file recorded in a manifest
  $PROG help                    show this help
  $PROG version                 show the version

Options:
  -m, --manifest <file>  manifest path (default: <dir>/.organize-manifest)
  -q, --quiet            only print errors

Categories: images video audio docs archives code other
EOF
}

# Map a file extension (lower case, no dot) to a category name.
categorize() {
	ext=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
	case "$ext" in
	jpg|jpeg|png|gif|webp|svg|bmp|heic|heif|tif|tiff|raw)
		echo images ;;
	mp4|mkv|avi|mov|wmv|flv|webm|m4v)
		echo video ;;
	mp3|wav|flac|m4a|ogg|opus|aac|wma)
		echo audio ;;
	pdf|txt|md|doc|docx|odt|rtf|xls|xlsx|csv|ppt|pptx|pages|numbers|key)
		echo docs ;;
	zip|tar|gz|bz2|xz|7z|rar|zst|tgz)
		echo archives ;;
	sh|bash|js|ts|jsx|tsx|py|rb|go|rs|java|c|h|cpp|hpp|json|yml|yaml|toml|xml|html|css|sql)
		echo code ;;
	*)
		echo other ;;
	esac
}

# Full path of the file this name would occupy after moving.
# Adds .1, .2, ... when the target already exists.
target_path() {
	dest_dir="$1"
	name="$2"
	candidate="$dest_dir/$name"
	if [ ! -e "$candidate" ]; then
		printf '%s\n' "$candidate"
		return 0
	fi
	base=$(printf '%s' "$name" | sed 's/\.[^.]*$//')
	suffix=$(printf '%s' "$name" | sed -n 's/^\.*.*\(\.[^.]*\)$/\1/p')
	[ -n "$suffix" ] && [ "$suffix" != "$name" ] || suffix=""
	i=1
	while :; do
		candidate="$dest_dir/$base.$i$suffix"
		[ -e "$candidate" ] || break
		i=$((i + 1))
	done
	printf '%s\n' "$candidate"
}

# Sets the global RESOLVED_DIR to an absolute path.
# NOTE: must not be called inside $(...) because die() needs to exit the script.
resolve_dir() {
	RESOLVED_DIR=""
	if [ ! -d "$1" ]; then
		die "not a directory: $1"
	fi
	case "$1" in
	/*) RESOLVED_DIR=$1 ;;
	*) RESOLVED_DIR=$(pwd)/$1 ;;
	esac
}

# Print the plan: "category<TAB>filename" for every top level file.
plan() {
	dir=$1
	found=0
	for f in "$dir"/*; do
		[ -e "$f" ] || continue
		[ -f "$f" ] || continue
		[ -L "$f" ] && continue
		name=$(basename "$f")
		case "$name" in
		.*|.organize-manifest*) continue ;;
		esac
		case "$name" in
		*.*) ext=${name##*.} ;;
		*) ext="" ;;
		esac
		cat=$(categorize "$ext")
		printf '%s\t%s\n' "$cat" "$name"
		found=1
	done
	[ "$found" -eq 1 ] || warn "no files to organize in $dir"
	return 0
}

do_scan() {
	resolve_dir "$1"
	dir=$RESOLVED_DIR
	plan "$dir" | sort | while IFS='	' read -r cat name; do
		[ -n "$cat" ] || continue
		printf '%-12s <- %s\n' "$cat" "$name"
	done
	return 0
}

do_move() {
	resolve_dir "$1"
	dir=$RESOLVED_DIR
	manifest=${MANIFEST:-$dir/.organize-manifest}
	[ -e "$manifest" ] && die "manifest already exists: $manifest (use -m or run undo first)"

	tmp=$(mktemp) || die "cannot create temp file"
	trap 'rm -f "$tmp"' EXIT INT TERM

	plan "$dir" >"$tmp" || true
	if [ ! -s "$tmp" ]; then
		info "nothing to do in $dir"
		return 0
	fi

	: >"$manifest.tmp" || die "cannot write manifest: $manifest"
	count=0
	while IFS='	' read -r cat name; do
		[ -n "$cat" ] || continue
		src="$dir/$name"
		[ -f "$src" ] || continue
		dest_dir="$dir/$cat"
		if [ ! -d "$dest_dir" ]; then
			mkdir -p "$dest_dir" || die "cannot create $dest_dir"
		fi
		dest=$(target_path "$dest_dir" "$name")
		if mv "$src" "$dest"; then
			printf '%s\t%s\n' "$src" "$dest" >>"$manifest.tmp" ||
				die "failed to record $src"
			count=$((count + 1))
		 info "$name -> $cat/"
		else
			warn "failed to move $src"
		fi
	done <"$tmp"

	mv "$manifest.tmp" "$manifest" || die "cannot write manifest: $manifest"
	info "moved $count file(s); manifest: $manifest"
	info "undo with: $PROG undo $manifest"
	return 0
}

do_undo() {
	manifest=$1
	[ -f "$manifest" ] || die "no such manifest: $manifest"
	restored=0
	skipped=0
	while IFS='	' read -r src dest; do
		[ -n "$src" ] || continue
		[ -e "$dest" ] || { skipped=$((skipped + 1)); continue; }
		parent=$(dirname "$src")
		[ -d "$parent" ] || mkdir -p "$parent"
		if mv "$dest" "$src"; then
			restored=$((restored + 1))
			info "$(basename "$src") <- restored"
		else
			warn "failed to restore $dest"
			skipped=$((skipped + 1))
		fi
	done <"$manifest"

	# remove category folders that are now empty
	dir=$(dirname "$manifest")
	for d in images video audio docs archives code other; do
		[ -d "$dir/$d" ] && rmdir "$dir/$d" 2>/dev/null
	done

	info "restored $restored file(s)"
	if [ "$skipped" -eq 0 ]; then
		# every file is back, so the manifest has served its purpose:
		# drop it, otherwise the next 'move' would refuse to run with
		# "manifest already exists (use -m or run undo first)".
		rm -f "$manifest" || warn "cannot remove $manifest"
	else
		warn "$skipped file(s) not restored (missing or failed) - keeping $manifest to retry"
	fi
	return 0
}

# --- argument parsing ---------------------------------------------------------

COMMAND=""
DIR=""

while [ $# -gt 0 ]; do
	case "$1" in
	help|--help|-h)
		[ -n "$COMMAND" ] || COMMAND="help" ;;
	version|--version|-V)
		[ -n "$COMMAND" ] || COMMAND="version" ;;
	scan|move|undo)
		if [ -n "$COMMAND" ]; then
			# second positional: the target (must actually be there -
			# under `set -u` a bare "$2" aborts the whole script)
			[ $# -ge 2 ] || die "usage: $PROG $COMMAND <dir>"
			if [ -z "$DIR" ]; then DIR="$2"; shift; fi
		else
			COMMAND="$1"
		fi ;;
	-m|--manifest)
		[ $# -ge 2 ] || die "$1 requires an argument"
		MANIFEST="$2"; shift ;;
	--manifest=*)
		MANIFEST=${1#--manifest=}; ;;
	-q|--quiet)
		QUIET=1 ;;
	-*)
		die "unknown option: $1 (try '$PROG help')" ;;
	*)
		if [ -z "$DIR" ]; then DIR="$1"; else die "unexpected argument: $1"; fi ;;
	esac
	shift
done

case "$COMMAND" in
""|help)
	usage
	[ -n "$COMMAND" ] && exit 0
	exit 1 ;;
version)
	printf '%s %s\n' "$PROG" "$VERSION"
	exit 0 ;;
scan)
	[ -n "$DIR" ] || die "usage: $PROG scan <dir>"
	do_scan "$DIR" ;;
move)
	[ -n "$DIR" ] || die "usage: $PROG move <dir>"
	do_move "$DIR" ;;
undo)
	[ -n "$DIR" ] || die "usage: $PROG undo <manifest>"
	do_undo "$DIR" ;;
esac
