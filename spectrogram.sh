#!/usr/bin/env bash
set -euo pipefail

# -----------------------------
# Tunables
# -----------------------------
TARGET_PX=3200     # pixel width for BOTH full & zoom images
ZOOM_SECS=2        # duration of the zoom window (seconds)
ZOOM_OFFSET=0      # start time for the zoom (seconds)

# -----------------------------
# Usage
# -----------------------------
usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS] [DIRECTORY]

Generate spectrograms and calculate crest factor (peak-to-RMS ratio) for audio files.

Options:
    -h, --help     Show this help message
    -w WIDTH       Set spectrogram width in pixels (default: $TARGET_PX)
    -z SECONDS     Set zoom window duration (default: $ZOOM_SECS)
    -o OFFSET      Set zoom window start offset (default: $ZOOM_OFFSET)

Arguments:
    DIRECTORY      Directory containing audio files (default: current directory)

Outputs:
    - PNG spectrograms (stacked full + zoom views)
    - crest_factor_flac.csv and crest_factor_wav.csv with metrics
EOF
    exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        -w) TARGET_PX="$2"; shift 2 ;;
        -z) ZOOM_SECS="$2"; shift 2 ;;
        -o) ZOOM_OFFSET="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  WORK_DIR="$1"; shift ;;
    esac
done

WORK_DIR="${WORK_DIR:-.}"
[[ -d "$WORK_DIR" ]] || { echo "Error: '$WORK_DIR' is not a directory" >&2; exit 1; }
cd "$WORK_DIR" || exit 1

# -----------------------------
# Package manager detection
# Checks for common package managers in order of prevalence.
# Returns the first available manager name, or empty string if none found.
# -----------------------------
detect_pkg_mgr() {
    local managers=(
        apt-get apt     # Debian/Ubuntu
        dnf yum         # Fedora/RHEL/CentOS
        pacman          # Arch Linux
        zypper          # openSUSE
        apk             # Alpine Linux
        xbps-install    # Void Linux
        emerge          # Gentoo
        nix-env         # NixOS
        brew            # macOS Homebrew
        pkg             # FreeBSD
    )
    for mgr in "${managers[@]}"; do
        if command -v "$mgr" &>/dev/null; then
            echo "$mgr"
            return 0
        fi
    done
    return 1
}

# -----------------------------
# Dependency installer
# Translates generic tool names to distro-specific package names
# and installs via the detected package manager.
# -----------------------------
install_dependency() {
    local want="$1"
    local mgr
    mgr=$(detect_pkg_mgr) || { echo "Error: No supported package manager found." >&2; exit 1; }

    # Map generic tool name to distro-specific package name
    local pkg="$want"
    case "$mgr" in
        apt-get|apt)    [[ "$want" == "imagemagick" ]] && pkg="imagemagick" ;;
        dnf|yum)        [[ "$want" == "imagemagick" ]] && pkg="ImageMagick" ;;
        pacman)         [[ "$want" == "imagemagick" ]] && pkg="imagemagick" ;;
        zypper)         [[ "$want" == "imagemagick" ]] && pkg="ImageMagick" ;;
        apk)            [[ "$want" == "imagemagick" ]] && pkg="imagemagick" ;;
        xbps-install)   [[ "$want" == "imagemagick" ]] && pkg="ImageMagick" ;;
        emerge)
            case "$want" in
                sox)         pkg="media-sound/sox" ;;
                imagemagick) pkg="media-gfx/imagemagick" ;;
                bc)          pkg="sys-devel/bc" ;;
            esac ;;
        nix-env)
            case "$want" in
                sox)         pkg="nixpkgs.sox" ;;
                imagemagick) pkg="nixpkgs.imagemagick" ;;
                bc)          pkg="nixpkgs.bc" ;;
            esac ;;
        brew)           [[ "$want" == "imagemagick" ]] && pkg="imagemagick" ;;
        pkg)
            case "$want" in
                sox)         pkg="sox" ;;
                imagemagick) pkg="ImageMagick7" ;;
                bc)          pkg="bc" ;;
            esac ;;
    esac

    echo "Installing $want via $mgr (package: $pkg)..."
    case "$mgr" in
        apt-get)      sudo apt-get update -y && sudo apt-get install -y "$pkg" ;;
        apt)          sudo apt update -y && sudo apt install -y "$pkg" ;;
        dnf)          sudo dnf install -y "$pkg" ;;
        yum)          sudo yum install -y "$pkg" ;;
        pacman)       sudo pacman -Syu --noconfirm --needed "$pkg" ;;
        zypper)       sudo zypper --non-interactive in "$pkg" ;;
        apk)          sudo apk add --no-cache "$pkg" ;;
        xbps-install) sudo xbps-install -y "$pkg" ;;
        emerge)       sudo emerge -n "$pkg" ;;
        nix-env)      nix-env -iA "$pkg" ;;
        brew)         brew install "$pkg" ;;
        pkg)          sudo pkg install -y "$pkg" ;;
        *)            echo "Unsupported manager: $mgr" >&2; exit 1 ;;
    esac
}

# -----------------------------
# Dependency checks
# Required tools:
#   sox      - Audio processing, resampling, spectrogram generation
#   soxi     - Audio file metadata extraction (part of sox)
#   bc       - Arbitrary precision calculator for crest factor math
#   magick   - ImageMagick for combining spectrogram images
# -----------------------------
for tool in sox bc; do
    command -v "$tool" &>/dev/null || install_dependency "$tool"
done
command -v magick &>/dev/null || install_dependency "imagemagick"

# -----------------------------
# CSV output management
# Creates the results CSV with headers on first write.
# Avoids overwriting existing data from previous runs.
# -----------------------------
ensure_results_header() {
    local format="$1"
    local file="crest_factor_${format}.csv"
    [[ -f "$file" ]] || echo "File,Crest Factor (dB),Peak (dB),RMS (dB),Bit Depth" > "$file"
}

# -----------------------------
# Crest factor calculation
#
# Crest factor (peak-to-RMS ratio) measures the "peakiness" of a waveform.
# Higher values indicate more dynamic range; heavily compressed audio
# will have lower crest factors (typically 6-10 dB for pop music,
# 15-20+ dB for classical or acoustic recordings).
#
# Formula: Crest Factor (dB) = Peak Level (dB) - RMS Level (dB)
#
# Note: This is sometimes incorrectly called "DNR" (Dynamic Noise Ratio),
# but DNR specifically refers to signal-to-noise floor measurements.
# -----------------------------
calculate_crest_factor() {
    local file="$1" format="$2"
    local results_file="crest_factor_${format}.csv"

    # Detect actual bit depth from file metadata (don't assume based on format)
    local bit_depth
    bit_depth=$(soxi -b "$file" 2>/dev/null) || bit_depth=16

    local stats peak rms crest_factor
    if ! stats=$(sox "$file" -n stats -b "$bit_depth" 2>&1); then
        echo "  Error: sox stats failed for $file" >&2
        echo "  Debug output:" >&2
        echo "$stats" | sed 's/^/    /' >&2
        return 1
    fi

    # Extract peak and RMS levels from sox stats output
    peak=$(echo "$stats" | awk '/Pk lev dB/ {print $4}')
    rms=$(echo "$stats" | awk '/RMS lev dB/ {print $4}')

    # Validate that we got numeric values before calculating
    if [[ "$peak" =~ ^-?[0-9.]+$ && "$rms" =~ ^-?[0-9.]+$ ]]; then
        ensure_results_header "$format"
        # Both values are in dB, so subtraction gives ratio in dB
        crest_factor=$(echo "scale=2; $peak - ($rms)" | bc -l)
        echo "\"$file\",$crest_factor,$peak,$rms,$bit_depth" >> "$results_file"
        echo "  Crest factor: ${crest_factor} dB (Peak: ${peak} dB, RMS: ${rms} dB, ${bit_depth}-bit)"
    else
        echo "  Error: could not parse audio stats" >&2
        echo "  Peak='$peak' RMS='$rms'" >&2
        echo "  Raw stats:" >&2
        echo "$stats" | sed 's/^/    /' >&2
        return 1
    fi
}

# -----------------------------
# Spectrogram generation
#
# For each audio file:
#   1. Resamples to 48kHz to cap the spectrogram at 24kHz (Nyquist)
#      This ensures consistent, comparable output regardless of source sample rate
#   2. Generates full-length spectrogram at fixed pixel width
#   3. Generates zoomed spectrogram of first N seconds for detail analysis
#   4. Stacks both images vertically into final output
#   5. Calculates and logs crest factor metrics
# -----------------------------
process_audio() {
    local format="$1"
    echo -e "\nProcessing $format files..."

    shopt -s nullglob
    local matched=(*."$format")
    shopt -u nullglob

    if (( ${#matched[@]} == 0 )); then
        echo "  No .$format files found — skipping."
        return 0
    fi

    for file in "${matched[@]}"; do
        [[ -f "$file" ]] || continue

        local filename basename title full_png zoomed_png final_png
        filename=$(basename -- "$file")
        basename="${filename%.*}"
        # Escape quotes in filename for sox title display
        title="${filename//\"/\\\"}"
        title="${title//\'/\'\\\'\'}"

        full_png="${basename}_full.png"
        zoomed_png="${basename}_zoomed.png"
        final_png="${basename}.png"

        echo "Analyzing: $filename  (width: ${TARGET_PX}px; @48k → 0–24 kHz)"

        # Generate full-length spectrogram
        # rate -v 48000: resample with very-high-quality algorithm
        # -x: set output image width in pixels
        local err exit_code
        err=$(sox "$file" -n rate -v 48000 spectrogram -x "$TARGET_PX" -t "$title" -o "$full_png" 2>&1) || exit_code=$?
        if [[ ${exit_code:-0} -ne 0 ]]; then
            echo "  ERROR: spectrogram failed for full image" >&2
            [[ -n "$err" ]] && echo "$err" > "${basename}_full.err"
            rm -f "$full_png"
            continue
        fi

        # Generate zoomed spectrogram for detailed frequency analysis
        # trim: extract specific time window (offset + duration)
        err=$(sox "$file" -n rate -v 48000 trim "$ZOOM_OFFSET" "$ZOOM_SECS" spectrogram -x "$TARGET_PX" -t "${title} (zoom)" -o "$zoomed_png" 2>&1) || exit_code=$?
        if [[ ${exit_code:-0} -ne 0 ]]; then
            echo "  ERROR: spectrogram failed for zoom image" >&2
            [[ -n "$err" ]] && echo "$err" > "${basename}_zoomed.err"
            rm -f "$full_png" "$zoomed_png"
            continue
        fi

        # Stack full and zoomed spectrograms vertically
        if [[ -f "$full_png" && -f "$zoomed_png" ]]; then
            magick "$full_png" "$zoomed_png" -append "$final_png"
            rm -f "$full_png" "$zoomed_png"
        else
            echo "  Warning: spectrogram(s) missing for $filename" >&2
        fi

        # Calculate and log audio metrics
        calculate_crest_factor "$file" "$format" || true
    done
}

# -----------------------------
# Main entry point
# -----------------------------
process_audio "flac"
process_audio "wav"

echo -e "\nAnalysis complete!"
[[ -f crest_factor_flac.csv ]] && echo "• FLAC metrics: crest_factor_flac.csv"
[[ -f crest_factor_wav.csv  ]] && echo "• WAV metrics: crest_factor_wav.csv"
echo "• Spectrograms saved as PNG files (stacked full + zoom views)"
