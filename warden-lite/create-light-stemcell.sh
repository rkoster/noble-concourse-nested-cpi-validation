#!/bin/bash

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <image_url> [output_file]"
    echo "Example: $0 ghcr.io/cloudfoundry/ubuntu-jammy-stemcell:latest light-stemcell-jammy.tgz"
    exit 1
fi

IMAGE_URL="$1"
OUTPUT_FILE="${2:-light-stemcell.tgz}"

IMAGE_NAME=$(echo "$IMAGE_URL" | sed 's|.*/||' | sed 's|[@:].*||')
IMAGE_TAG=$(echo "$IMAGE_URL" | grep -o ':[^@]*$' | sed 's/^://' || echo "latest")

OS_NAME=$(echo "$IMAGE_NAME" | sed 's|-stemcell$||')

echo "Creating light stemcell for image: $IMAGE_URL"
echo "Image name: $IMAGE_NAME"
echo "Image tag: $IMAGE_TAG"
echo "OS: $OS_NAME"

TEMP_DIR=$(mktemp -d)
trap "rm -rf $TEMP_DIR" EXIT

cat > "$TEMP_DIR/stemcell.MF" <<EOF
---
name: bosh-warden-${OS_NAME}
version: "${IMAGE_TAG}"
api_version: 3
bosh_protocol: '1'
sha1: da39a3ee5e6b4b0d3255bfef95601890afd80709
operating_system: ${OS_NAME}
stemcell_formats:
- docker-light
cloud_properties:
  image_reference: "${IMAGE_URL}"
EOF

if command -v docker &> /dev/null; then
    echo "Docker found, attempting to pull image and extract digest..."
    
    if docker pull "$IMAGE_URL" 2>/dev/null; then
        DIGEST=$(docker inspect "$IMAGE_URL" --format='{{index .RepoDigests 0}}' 2>/dev/null | grep -o 'sha256:[a-f0-9]*' || echo "")
        
        if [ -n "$DIGEST" ]; then
            echo "Found image digest: $DIGEST"
            echo "  digest: \"$DIGEST\"" >> "$TEMP_DIR/stemcell.MF"
        else
            echo "Warning: Could not extract digest from image"
        fi
    else
        echo "Warning: Could not pull image. Proceeding without digest verification."
        echo "Note: For private registries, ensure you're authenticated with 'docker login'"
    fi
else
    echo "Docker not available. Creating light stemcell without digest verification."
fi

touch "$TEMP_DIR/image"

echo ""
echo "Stemcell metadata:"
cat "$TEMP_DIR/stemcell.MF"
echo ""

echo "Creating archive: $OUTPUT_FILE"
tar -czf "$OUTPUT_FILE" -C "$TEMP_DIR" stemcell.MF image

echo ""
echo "✅ Light stemcell created successfully: $OUTPUT_FILE"
echo "Size: $(du -h "$OUTPUT_FILE" | cut -f1)"
echo ""
echo "You can upload this stemcell to BOSH with:"
echo "  bosh upload-stemcell $OUTPUT_FILE"
