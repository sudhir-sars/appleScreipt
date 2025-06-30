cat > build.sh << 'EOF'
#!/bin/bash

# Simple build script without signing or entitlements

SWIFT_FILE="CaptureProcess.swift"
OUTPUT_NAME="CaptureProcess"

echo "Building $OUTPUT_NAME..."

# Build command
swiftc -o $OUTPUT_NAME $SWIFT_FILE \
  -framework AVFoundation \
  -framework ScreenCaptureKit \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework Foundation \
  -framework CoreAudio \
  -g

if [ $? -eq 0 ]; then
    chmod +x $OUTPUT_NAME
    echo "✓ Build successful!"
    echo "✓ Output size: $(ls -lh $OUTPUT_NAME | awk '{print $5}')"
else
    echo "✗ Build failed!"
    exit 1
fi
EOF

chmod +x build.sh