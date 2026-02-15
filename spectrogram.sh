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
Usage: $(basename "$0") [OPTIONS] [AUDIO_DIR] [OUTPUT_DIR]

Generate spectrograms and calculate crest factor (peak-to-RMS ratio) for audio files.

Options:
    -h, --help     Show this help message
    -w WIDTH       Set spectrogram width in pixels (default: $TARGET_PX)
    -z SECONDS     Set zoom window duration (default: $ZOOM_SECS)
    -o OFFSET      Set zoom window start offset (default: $ZOOM_OFFSET)

Arguments:
    AUDIO_DIR      Directory containing audio files (default: current directory)
    OUTPUT_DIR     Directory for output PNGs and CSVs (default: current directory)

Outputs:
    - PNG spectrograms (stacked full + zoom views)
    - crest_factor_flac.csv and crest_factor_wav.csv with metrics
EOF
    exit 0
}

# Parse arguments
positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        -w) TARGET_PX="$2"; shift 2 ;;
        -z) ZOOM_SECS="$2"; shift 2 ;;
        -o) ZOOM_OFFSET="$2"; shift 2 ;;
        -*) echo "Unknown option: $1" >&2; exit 1 ;;
        *)  positional+=("$1"); shift ;;
    esac
done

AUDIO_DIR="$(realpath "${positional[0]:-.}")"
OUTPUT_DIR="${positional[1]:-.}"
[[ -d "$AUDIO_DIR" ]] || { echo "Error: not a directory: $AUDIO_DIR" >&2; exit 1; }
mkdir -p "$OUTPUT_DIR" || { echo "Error: cannot create output directory: $OUTPUT_DIR" >&2; exit 1; }
cd "$OUTPUT_DIR" || { echo "Error: cannot cd to $OUTPUT_DIR" >&2; exit 1; }

# -----------------------------
# Package manager detection
# Checks for common package managers in order of prevalence.
# Returns the first available manager name.
# -----------------------------
detect_pkg_mgr() {
    local managers=(
        apt-get apt     # Debian/Ubuntu (apt-get preferred for non-interactive use)
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

    # Override only where the package name differs from the tool name
    local pkg="$want"
    case "$mgr" in
        dnf|yum|zypper|xbps-install)
            if [[ "$want" == "imagemagick" ]]; then pkg="ImageMagick"; fi ;;
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
        pkg)
            if [[ "$want" == "imagemagick" ]]; then pkg="ImageMagick7"; fi ;;
    esac

    echo "Installing $want via $mgr (package: $pkg)..."
    case "$mgr" in
        apt-get)      sudo apt-get update -y && sudo apt-get install -y "$pkg" ;;
        apt)          sudo apt update -y && sudo apt install -y "$pkg" ;;
        dnf)          sudo dnf install -y "$pkg" ;;
        yum)          sudo yum install -y "$pkg" ;;
        pacman)       sudo pacman -S --noconfirm --needed "$pkg" ;;
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
        printf '    %s\n' "$stats" >&2
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
        printf '    %s\n' "$stats" >&2
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
process_audio() (
    local format="$1" srcdir="$2"
    echo -e "\nProcessing ${format} files..."

    shopt -s nullglob
    local matched=("${srcdir}"/*."${format}")
    if (( ${#matched[@]} == 0 )); then
        echo "  No .${format} files found -- skipping."
        return 0
    fi

    for file in "${matched[@]}"; do
        [[ -f "$file" ]] || continue

        local filename basename err rc
        filename=$(basename -- "$file")
        basename="${filename%.*}"

        echo "Analyzing: $filename  (width: ${TARGET_PX}px; @48k -> 0-24 kHz)"

        # Full-length spectrogram (resample to 48k; set exact width with -x)
        err=$(sox "$file" -n rate -v 48000 spectrogram -x "$TARGET_PX" -t "$filename" -o "${basename}_full.png" 2>&1) || rc=$?
        if [[ ${rc:-0} -ne 0 ]]; then
            echo "  ERROR: spectrogram failed for full image" >&2
            [[ -n "$err" ]] && echo "$err" > "${basename}_full.err"
            rc=0; continue
        fi

        # Zoom spectrogram (same exact width; different time window)
        local duration
        duration=$(soxi -D "$file" 2>/dev/null || echo 0)
        if (( $(echo "$duration < $ZOOM_OFFSET + $ZOOM_SECS" | bc -l) )); then
            echo "  Skipping zoom: file shorter than offset+duration"
        else
            err=$(sox "$file" -n rate -v 48000 trim "$ZOOM_OFFSET" "$ZOOM_SECS" spectrogram -x "$TARGET_PX" -t "$filename (zoom)" -o "${basename}_zoomed.png" 2>&1) || rc=$?
            if [[ ${rc:-0} -ne 0 ]]; then
                echo "  ERROR: spectrogram failed for zoom image" >&2
                [[ -n "$err" ]] && echo "$err" > "${basename}_zoomed.err"
                rc=0; continue
            fi
        fi

        if [[ -f "${basename}_full.png" && -f "${basename}_zoomed.png" ]]; then
            if magick "${basename}_full.png" "${basename}_zoomed.png" -append "${basename}.png"; then
                rm -f "${basename}"_{full,zoomed}.png
            else
                echo "  Warning: magick failed; intermediate PNGs retained" >&2
            fi
        elif [[ -f "${basename}_full.png" ]]; then
            mv "${basename}_full.png" "${basename}.png"
        else
            echo "  Warning: spectrogram(s) missing for $filename" >&2
        fi

        calculate_crest_factor "$file" "${format}" || true
    done
)

# -----------------------------
# Main entry point
# -----------------------------
process_audio "flac" "$AUDIO_DIR"
process_audio "wav" "$AUDIO_DIR"

echo -e "\nAnalysis complete!"
[[ -f crest_factor_flac.csv ]] && echo "  FLAC metrics: $OUTPUT_DIR/crest_factor_flac.csv"
[[ -f crest_factor_wav.csv  ]] && echo "  WAV metrics:  $OUTPUT_DIR/crest_factor_wav.csv"
echo -e "\nSpectrograms saved to $OUTPUT_DIR"
