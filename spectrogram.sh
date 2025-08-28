#!/bin/bash
set -u

# -----------------------------
# Tunables
# -----------------------------
TARGET_PX=3200     # pixel width for BOTH full & zoom images
ZOOM_SECS=2        # duration of the zoom window (seconds)
ZOOM_OFFSET=0      # start time for the zoom (seconds)

# -----------------------------
# Package manager detection
# -----------------------------
detect_pkg_mgr() {
    for mgr in apt-get apt dnf yum pacman zypper apk xbps-install emerge nix-env brew pkg; do
        if command -v "$mgr" &>/dev/null; then
            echo "$mgr"; return 0
        fi
    done
    echo ""; return 1
}

install_dependency() {
    local want="$1"
    local mgr; mgr=$(detect_pkg_mgr) || true
    [[ -z "$mgr" ]] && { echo "Error: No supported package manager found."; exit 1; }

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
        brew)            [[ "$want" == "imagemagick" ]] && pkg="imagemagick" ;;
        pkg)
            case "$want" in
                sox)         pkg="sox" ;;
                imagemagick) pkg="ImageMagick7" ;;
                bc)          pkg="bc" ;;
            esac ;;
    esac

    echo "Installing $want via $mgr (pkg: $pkg)..."
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
        *)            echo "Unsupported manager: $mgr"; exit 1 ;;
    esac
}

# -----------------------------
# Dependency checks
# -----------------------------
for tool in sox bc; do
    command -v "$tool" &>/dev/null || install_dependency "$tool"
done
command -v magick &>/dev/null || install_dependency "imagemagick"

# -----------------------------
# Lazy CSV header creation
# -----------------------------
ensure_results_header() {
    local format="$1"
    local file="dnr_results_${format}.csv"
    [[ -f "$file" ]] || echo "File,DNR (dB),Peak (dB),RMS (dB)" > "$file"
}

# -----------------------------
# DNR calculation
# -----------------------------
calculate_dnr() {
    local file="$1" format="$2"
    local results_file="dnr_results_${format}.csv"
    local bit_depth=16
    [[ "$format" == "flac" ]] && bit_depth=24

    local stats peak rms dnr
    stats=$(sox "$file" -n stats -b "$bit_depth" 2>&1)
    peak=$(echo "$stats" | awk '/Pk lev dB/ {print $4}')
    rms=$(echo "$stats" | awk '/RMS lev dB/ {print $4}')

    if [[ "$peak" =~ ^-?[0-9.]+$ && "$rms" =~ ^-?[0-9.]+$ ]]; then
        ensure_results_header "$format"
        dnr=$(echo "scale=2; $peak - $rms" | bc -l)
        echo "\"$file\",$dnr,$peak,$rms" >> "$results_file"
        echo "  DNR: ${dnr} dB (Peak: ${peak} dB, RMS: ${rms} dB)"
    else
        echo "  Error calculating DNR"
        echo "  Debug output:"; echo "$stats" | sed 's/^/    /'
    fi
}

# -----------------------------
# Spectrograms (48k resample → 0–24 kHz, fixed width)
# -----------------------------
process_audio() {
    local format="$1"
    echo -e "\nProcessing $format files..."

    shopt -s nullglob
    local matched=(*."$format")
    if (( ${#matched[@]} == 0 )); then
        echo "  No .$format files found — skipping."
        shopt -u nullglob; return 0
    fi

    for file in "${matched[@]}"; do
        [[ -f "$file" ]] || continue

        local filename basename title err
        filename=$(basename -- "$file")
        basename="${filename%.*}"
        title="${filename//\'/’}"

        echo "Analyzing: $filename  (width: ${TARGET_PX}px; @48k → 0–24 kHz)"

        # Full-length spectrogram (resample to 48k; set exact width with -x)
        err=$(sox "$file" -n rate -v 48000 spectrogram -x "$TARGET_PX" -t "$title" -o "${basename}_full.png" 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "  ERROR: spectrogram failed for full image"
            [[ -n "$err" ]] && echo "$err" > "${basename}_full.err"
            continue
        fi

        # Zoom spectrogram (same exact width; different time window)
        err=$(sox "$file" -n rate -v 48000 trim "$ZOOM_OFFSET" "$ZOOM_SECS" spectrogram -x "$TARGET_PX" -t "${title} (zoom)" -o "${basename}_zoomed.png" 2>&1)
        if [[ $? -ne 0 ]]; then
            echo "  ERROR: spectrogram failed for zoom image"
            [[ -n "$err" ]] && echo "$err" > "${basename}_zoomed.err"
            continue
        fi

        if [[ -f "${basename}_full.png" && -f "${basename}_zoomed.png" ]]; then
            magick "${basename}_full.png" "${basename}_zoomed.png" -append "${basename}.png"
            rm -f "${basename}"_{full,zoomed}.png
        else
            echo "  Warning: spectrogram(s) missing for $filename"
        fi

        calculate_dnr "$filename" "$format"
    done
    shopt -u nullglob
}

# -----------------------------
# Main
# -----------------------------
process_audio "flac"
process_audio "wav"

echo -e "\nAnalysis complete!"
[[ -f dnr_results_flac.csv ]] && echo "• FLAC: dnr_results_flac.csv"
[[ -f dnr_results_wav.csv  ]] && echo "• WAV: dnr_results_wav.csv"
echo -e "\nSpectrograms saved as PNG files with names matching audio files"
