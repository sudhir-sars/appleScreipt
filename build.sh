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
FRAMEWORKS=("AVFoundation" "ScreenCaptureKit" "CoreGraphics" "CoreMedia" "Foundation" "CoreAudio")
ENTITLEMENTS_FILE="CaptureProcess.entitlements"
INFO_PLIST_FILE="Info.plist"

# Default options
OPTIMIZATION="-Onone"  # Debug mode by default
CLEAN=false
VERBOSE=false
SKIP_VERIFY=false
SHOW_HELP=false
SIGN_APP=true
CREATE_FILES=false

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
        --no-sign)
            SIGN_APP=false
            shift
            ;;
        --create-files)
            CREATE_FILES=true
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
  --no-sign          Skip code signing (not recommended)
  --create-files     Create entitlements and Info.plist files
  --help, -h         Show this help message

${CYAN}Examples:${RESET}
  ./build.sh                    # Debug build
  ./build.sh --release          # Release build
  ./build.sh --clean --release  # Clean release build
  ./build.sh --create-files     # Create required files first time
  ./build.sh --verbose          # Debug build with details

${CYAN}Configuration:${RESET}
  Source file:   $SWIFT_FILE
  Output:        $OUTPUT_NAME
  Entitlements:  $ENTITLEMENTS_FILE
  Info.plist:    $INFO_PLIST_FILE
  Frameworks:    ${FRAMEWORKS[*]}

${CYAN}Required Permissions:${RESET}
  • Microphone access (for audio input)
  • Screen Recording (for screen capture & system audio)
  
  These will be requested when the app runs.
EOF
}

# Create entitlements file
create_entitlements() {
    if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
        log "step" "📝 Creating $ENTITLEMENTS_FILE..."
        cat > "$ENTITLEMENTS_FILE" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.device.audio-input</key>
    <true/>
    <key>com.apple.security.cs.allow-jit</key>
    <true/>
    <key>com.apple.security.cs.allow-unsigned-executable-memory</key>
    <true/>
    <key>com.apple.security.cs.disable-library-validation</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
</dict>
</plist>
EOF
        log "success" "✓ Created $ENTITLEMENTS_FILE"
    else
        log "info" "✓ $ENTITLEMENTS_FILE already exists"
    fi
}

# Create Info.plist file
create_info_plist() {
    if [[ ! -f "$INFO_PLIST_FILE" ]]; then
        log "step" "📝 Creating $INFO_PLIST_FILE..."
        cat > "$INFO_PLIST_FILE" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.capture.process</string>
    <key>CFBundleName</key>
    <string>CaptureProcess</string>
    <key>CFBundleVersion</key>
    <string>1.0.0</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>This app needs access to your microphone to capture audio input from devices.</string>
    <key>NSScreenCaptureUsageDescription</key>
    <string>This app needs screen recording permission to capture screen content and system audio.</string>
</dict>
</plist>
EOF
        log "success" "✓ Created $INFO_PLIST_FILE"
    else
        log "info" "✓ $INFO_PLIST_FILE already exists"
    fi
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
            log "error" "✗ ScreenCaptureKit requires macOS 12.3 or later"
            log "error" "  Current version: $OS_VERSION"
            exit 1
        else
            log "success" "✓ macOS $OS_VERSION is compatible"
        fi
    fi
    
    # Check for required files when signing
    if [[ "$SIGN_APP" == true ]]; then
        if [[ ! -f "$ENTITLEMENTS_FILE" ]]; then
            log "warn" "⚠️  $ENTITLEMENTS_FILE not found"
            log "info" "  Run with --create-files to create required files"
            create_entitlements
        fi
        
        if [[ ! -f "$INFO_PLIST_FILE" ]]; then
            log "warn" "⚠️  $INFO_PLIST_FILE not found"
            log "info" "  Run with --create-files to create required files"
            create_info_plist
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
        
        # Clean up log files
        local LOG_COUNT=$(ls -1 capture_process_*.log 2>/dev/null | wc -l)
        if [[ $LOG_COUNT -gt 0 ]]; then
            rm -f capture_process_*.log
            log "success" "✓ Removed $LOG_COUNT log file(s)"
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
    ADDITIONAL_FLAGS="-g"  # Include debug symbols
    
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

# Sign the executable
sign_executable() {
    if [[ "$SIGN_APP" == true ]]; then
        echo ""
        log "step" "🔏 Signing executable..."
        
        # Check if we have a developer certificate
        if security find-identity -v -p codesigning | grep -q "Developer ID"; then
            # Sign with developer certificate
            SIGN_IDENTITY=$(security find-identity -v -p codesigning | grep "Developer ID" | head -1 | awk '{print $2}')
            log "info" "Found signing identity: ${SIGN_IDENTITY:0:8}..."
            
            if codesign --force --sign "$SIGN_IDENTITY" --entitlements "$ENTITLEMENTS_FILE" "$OUTPUT_NAME" 2>/dev/null; then
                log "success" "✓ Signed with developer certificate"
            else
                log "warn" "⚠️  Failed to sign with developer certificate, using ad-hoc signing"
                codesign --force --sign - --entitlements "$ENTITLEMENTS_FILE" "$OUTPUT_NAME"
                log "success" "✓ Signed with ad-hoc signature"
            fi
        else
            # Ad-hoc signing
            codesign --force --sign - --entitlements "$ENTITLEMENTS_FILE" "$OUTPUT_NAME"
            log "success" "✓ Signed with ad-hoc signature"
        fi
        
        # Verify signature
        if codesign --verify --verbose "$OUTPUT_NAME" 2>/dev/null; then
            log "success" "✓ Signature verified"
        else
            log "warn" "⚠️  Signature verification failed"
        fi
    fi
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
        
        # Check entitlements
        if command -v codesign &> /dev/null && [[ "$SIGN_APP" == true ]]; then
            if codesign -d --entitlements - "$OUTPUT_NAME" 2>/dev/null | grep -q "audio-input"; then
                log "success" "✓ Audio input entitlement present"
            else
                log "warn" "⚠️  Audio input entitlement not found"
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

# Check permissions
check_permissions() {
    echo ""
    log "step" "🔐 Checking system permissions..."
    
    # Check if terminal has microphone access (if running from terminal)
    if [[ "$TERM_PROGRAM" != "" ]]; then
        log "info" "Running from: $TERM_PROGRAM"
        log "warn" "⚠️  Make sure $TERM_PROGRAM has microphone access in System Preferences"
    fi
    
    log "info" ""
    log "info" "Required permissions:"
    log "info" "  • Microphone: System Preferences > Privacy & Security > Microphone"
    log "info" "  • Screen Recording: System Preferences > Privacy & Security > Screen Recording"
    log "info" ""
    log "info" "The app will request these permissions when first run."
}

# Show success message
show_success() {
    echo ""
    echo -e "${GREEN}${BOLD}✨ Build successful!${RESET}"
    echo ""
    echo -e "${CYAN}Required permissions:${RESET}"
    echo -e "  • ${YELLOW}Microphone${RESET} - for audio input capture"
    echo -e "  • ${YELLOW}Screen Recording${RESET} - for screen & system audio capture"
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
    echo -e "  4. Check log files:"
    echo -e "     ${YELLOW}ls -la capture_process_*.log${RESET}"
    echo ""
    
    if [[ "$SIGN_APP" == false ]]; then
        log "warn" "⚠️  App was not signed. Some features may not work properly."
        log "info" "  Run without --no-sign to enable code signing."
    fi
}

# Main execution
main() {
    echo -e "${BOLD}🚀 Swift Capture Process Builder${RESET}"
    echo ""
    
    if [[ "$SHOW_HELP" == true ]]; then
        show_help
        exit 0
    fi
    
    if [[ "$CREATE_FILES" == true ]]; then
        log "step" "📁 Creating required files..."
        create_entitlements
        create_info_plist
        echo ""
        log "success" "✓ Files created successfully!"
        log "info" "  Now run ./build.sh to build the executable"
        exit 0
    fi
    
    # Run build steps
    check_prerequisites
    clean_build
    create_build_dir
    build_swift
    sign_executable
    verify_executable
    check_permissions
    show_success
}

# Run the build
main