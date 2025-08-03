#!/bin/bash

# Function to install missing packages
install_dependency() {
    local pkg=$1
    echo "Installing $pkg..."
    
    if command -v apt-get &> /dev/null; then
        sudo apt-get install -y "$pkg"
    elif command -v yum &> /dev/null; then
        sudo yum install -y "$pkg"
    elif command -v brew &> /dev/null; then
        brew install "$pkg"
    else
        echo "Error: Could not determine package manager to install $pkg"
        exit 1
    fi
}

# Check and install dependencies
for pkg in sox imagemagick bc; do
    if ! command -v "$pkg" &> /dev/null; then
        install_dependency "$pkg"
    fi
done

# Initialize results files with headers
results_files=("dnr_results_flac.csv" "dnr_results_wav.csv")
for file in "${results_files[@]}"; do
    echo "File,DNR (dB),Peak (dB),RMS (dB)" > "$file"
done

# Function to calculate DNR with proper error handling
calculate_dnr() {
    local file=$1
    local format=$2
    local results_file="dnr_results_${format}.csv"
    
    # Get audio statistics with appropriate bit depth
    local bit_depth=16
    [[ "$format" == "flac" ]] && bit_depth=24
    
    local stats=$(sox "$file" -n stats -b $bit_depth 2>&1)
    local peak=$(echo "$stats" | awk '/Pk lev dB/ {print $4}')
    local rms=$(echo "$stats" | awk '/RMS lev dB/ {print $4}')
    
    if [[ "$peak" =~ ^-?[0-9.]+$ && "$rms" =~ ^-?[0-9.]+$ ]]; then
        local dnr=$(echo "scale=2; $peak - $rms" | bc -l)
        echo "\"$file\",$dnr,$peak,$rms" >> "$results_file"
        echo "  DNR: ${dnr} dB (Peak: ${peak} dB, RMS: ${rms} dB)"
    else
        echo "\"$file\",ERROR,,$stats" >> "$results_file"
        echo "  Error calculating DNR"
        echo "  Debug output:"
        echo "$stats" | sed 's/^/    /'
    fi
}

# Process audio files
process_audio() {
    local format=$1
    echo -e "\nProcessing $format files..."
    
    for file in *."$format"; do
        [ -f "$file" ] || continue
        
        local filename=$(basename -- "$file")
        local basename="${filename%.*}"
        
        echo "Analyzing: $filename"
        
        # Create spectrograms
        sox "$file" -n spectrogram -t "$filename" -o "${basename}_full.png" 2>/dev/null
        sox "$file" -n trim 0 2 spectrogram -t "${filename} (zoom)" -o "${basename}_zoomed.png" 2>/dev/null
        convert "${basename}_full.png" "${basename}_zoomed.png" -append "${basename}.png"
        rm "${basename}"_{full,zoomed}.png
        
        # Calculate DNR
        calculate_dnr "$filename" "$format"
    done
}

# Main processing
process_audio "flac"
process_audio "wav"

# Final output
echo -e "\nAnalysis complete! Results saved to:"
echo "• FLAC: dnr_results_flac.csv"
echo "• WAV: dnr_results_wav.csv"
echo -e "\nSpectrograms saved as PNG files with names matching audio files"