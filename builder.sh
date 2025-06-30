#!/bin/bash

# Build script for Swift Audio/Video Capture Process
# Usage: ./build.sh [options]

# ANSI color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
RESET='\033[0m'

# Configuration
SWIFT_FILE="CaptureProcess.swift"
OUTPUT_NAME="CaptureProcess"
BUILD_DIR="build"
FRAMEWORKS=("AVFoundation" "ScreenCaptureKit" "CoreGraphics" "CoreMedia" "Foundation")

# Default options
OPTIMIZATION="-Onone"  # Debug mode by default
CLEAN=false
VERBOSE=false
SKIP_VERIFY=false
SHOW_HELP=false

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --release)
            OPTIMIZATION="-O"
            shift
            ;;
        --clean)
            CLEAN=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --skip-verify)
            SKIP_VERIFY=true
            shift
            ;;
        --help|-h)
            SHOW_HELP=true
            shift
            ;;
        *)
            echo -e "${RED}Unknown option: $1${RESET}"
            exit 1
            ;;
    esac
done

# Logger function
log() {
    local level=$1
    local message=$2
    local color=$RESET
    
    case $level in
        "info") color=$BLUE ;;
        "success") color=$GREEN ;;
        "error") color=$RED ;;
        "warn") color=$YELLOW ;;
        "step") color=$CYAN ;;
    esac
    
    echo -e "${color}${message}${RESET}"
}

# Show help
show_help() {
    cat << EOF
${BOLD}Swift Capture Process Build Script${RESET}

${CYAN}Usage:${RESET}
  ./build.sh [options]

${CYAN}Options:${RESET}
  --release          Build with optimizations (production)
  --clean            Clean build artifacts before building
  --verbose          Show detailed build information
  --skip-verify      Skip executable verification
  --help, -h         Show this help message

${CYAN}Examples:${RESET}
  ./build.sh                    # Debug build
  ./build.sh --release          # Release build
  ./build.sh --clean --release  # Clean release build
  ./build.sh --verbose          # Debug build with details

${CYAN}Configuration:${RESET}
  Source file:  $SWIFT_FILE
  Output:       $OUTPUT_NAME
  Frameworks:   ${FRAMEWORKS[*]}
EOF
}

# Check prerequisites
check_prerequisites() {
    log "step" "🔍 Checking prerequisites..."
    
    # Check if Swift is installed
    if ! command -v swift &> /dev/null; then
        log "error" "✗ Swift not found. Please install Xcode or Swift toolchain"
        echo -e "${YELLOW}Install with: xcode-select --install${RESET}"
        exit 1
    fi
    
    # Get Swift version
    SWIFT_VERSION=$(swift --version 2>&1 | grep -o 'Swift version [0-9.]*' | cut -d' ' -f3)
    log "success" "✓ Swift $SWIFT_VERSION found"
    
    # Check if source file exists
    if [[ ! -f "$SWIFT_FILE" ]]; then
        log "error" "✗ Source file '$SWIFT_FILE' not found"
        exit 1
    fi
    log "success" "✓ Source file '$SWIFT_FILE' found"
    
    # Check macOS version (ScreenCaptureKit requires macOS 12.3+)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        OS_VERSION=$(sw_vers -productVersion)
        MAJOR_VERSION=$(echo $OS_VERSION | cut -d. -f1)
        MINOR_VERSION=$(echo $OS_VERSION | cut -d. -f2)
        
        if [[ $MAJOR_VERSION -lt 12 ]] || ([[ $MAJOR_VERSION -eq 12 ]] && [[ $MINOR_VERSION -lt 3 ]]); then
            log "warn" "⚠️  ScreenCaptureKit requires macOS 12.3 or later"
            log "warn" "  Current version: $OS_VERSION"
        else
            log "success" "✓ macOS $OS_VERSION is compatible"
        fi
    fi
}

# Clean build artifacts
clean_build() {
    if [[ "$CLEAN" == true ]]; then
        log "step" "🧹 Cleaning build artifacts..."
        
        if [[ -d "$BUILD_DIR" ]]; then
            rm -rf "$BUILD_DIR"
            log "success" "✓ Removed $BUILD_DIR directory"
        fi
        
        if [[ -f "$OUTPUT_NAME" ]]; then
            rm -f "$OUTPUT_NAME"
            log "success" "✓ Removed $OUTPUT_NAME executable"
        fi
    fi
}

# Create build directory
create_build_dir() {
    if [[ ! -d "$BUILD_DIR" ]]; then
        mkdir -p "$BUILD_DIR"
        log "success" "✓ Created $BUILD_DIR directory"
    fi
}

# Show spinner
spin() {
    local pid=$1
    local delay=0.1
    local spinstr='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    
    while ps -p $pid > /dev/null 2>&1; do
        local temp=${spinstr#?}
        printf " [%c] Compiling..." "${spinstr:0:1}"
        spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\r"
    done
    printf "    \r"
}

# Build the Swift executable
build_swift() {
    echo ""
    log "step" "🔨 Building $OUTPUT_NAME..."
    
    # Show build mode
    if [[ "$OPTIMIZATION" == "-O" ]]; then
        log "info" "Build mode: Release"
    else
        log "info" "Build mode: Debug"
    fi
    
    # Construct framework flags
    FRAMEWORK_FLAGS=""
    for fw in "${FRAMEWORKS[@]}"; do
        FRAMEWORK_FLAGS="$FRAMEWORK_FLAGS -framework $fw"
    done
    
    # Additional compiler flags
    ADDITIONAL_FLAGS="-warnings-as-errors -enable-bare-slash-regex"
    
    # Full build command
    BUILD_CMD="swiftc -o $OUTPUT_NAME $SWIFT_FILE $FRAMEWORK_FLAGS $OPTIMIZATION $ADDITIONAL_FLAGS"
    
    if [[ "$VERBOSE" == true ]]; then
        echo ""
        log "info" "Build command:"
        echo "  $BUILD_CMD"
        echo ""
    fi
    
    # Create temporary file for build output
    BUILD_OUTPUT=$(mktemp)
    
    # Start timer
    START_TIME=$(date +%s)
    
    # Run build command
    if [[ "$VERBOSE" == true ]]; then
        # Show full output in verbose mode
        eval "$BUILD_CMD" 2>&1 | tee "$BUILD_OUTPUT"
        BUILD_RESULT=${PIPESTATUS[0]}
    else
        # Run in background with spinner
        eval "$BUILD_CMD" > "$BUILD_OUTPUT" 2>&1 &
        BUILD_PID=$!
        spin $BUILD_PID
        wait $BUILD_PID
        BUILD_RESULT=$?
    fi
    
    # Calculate build time
    END_TIME=$(date +%s)
    BUILD_TIME=$((END_TIME - START_TIME))
    
    if [[ $BUILD_RESULT -eq 0 ]]; then
        log "success" "✓ Build completed in ${BUILD_TIME}s"
        
        # Make executable
        chmod +x "$OUTPUT_NAME"
        log "success" "✓ Made $OUTPUT_NAME executable"
        
        # Show file size
        if command -v ls &> /dev/null; then
            FILE_SIZE=$(ls -lh "$OUTPUT_NAME" | awk '{print $5}')
            log "info" "✓ Output size: $FILE_SIZE"
        fi
    else
        log "error" "✗ Build failed!"
        echo ""
        cat "$BUILD_OUTPUT"
        rm -f "$BUILD_OUTPUT"
        exit 1
    fi
    
    rm -f "$BUILD_OUTPUT"
}

# Verify the built executable
verify_executable() {
    if [[ "$SKIP_VERIFY" == false ]]; then
        echo ""
        log "step" "🧪 Verifying executable..."
        
        # Check if file exists and is executable
        if [[ -x "$OUTPUT_NAME" ]]; then
            log "success" "✓ File is executable"
        else
            log "error" "✗ File is not executable"
            exit 1
        fi
        
        # Check file type
        if command -v file &> /dev/null; then
            FILE_TYPE=$(file "$OUTPUT_NAME")
            if [[ $FILE_TYPE == *"Mach-O"* ]] && [[ $FILE_TYPE == *"executable"* ]]; then
                log "success" "✓ Valid macOS executable"
            else
                log "warn" "⚠️  Unexpected file type: $FILE_TYPE"
            fi
        fi
        
        # Show linked frameworks in verbose mode
        if [[ "$VERBOSE" == true ]] && command -v otool &> /dev/null; then
            echo ""
            log "info" "Linked frameworks:"
            otool -L "$OUTPUT_NAME" | grep -E "(framework|dylib)" | while read -r line; do
                echo "  $line"
            done
        fi
    fi
}

# Show success message
show_success() {
    echo ""
    echo -e "${GREEN}${BOLD}✨ Build successful!${RESET}"
    echo ""
    echo -e "${CYAN}Next steps:${RESET}"
    echo -e "  1. Run the capture process:"
    echo -e "     ${YELLOW}bun start${RESET}"
    echo ""
    echo -e "  2. Run in test mode (saves files):"
    echo -e "     ${YELLOW}bun run start:test${RESET}"
    echo ""
    echo -e "  3. Run automated demo:"
    echo -e "     ${YELLOW}bun run demo${RESET}"
    echo ""
}

# Main execution
main() {
    echo -e "${BOLD}🚀 Swift Capture Process Builder${RESET}"
    echo ""
    
    if [[ "$SHOW_HELP" == true ]]; then
        show_help
        exit 0
    fi
    
    # Run build steps
    check_prerequisites
    clean_build
    create_build_dir
    build_swift
    verify_executable
    show_success
}

# Run the build
main