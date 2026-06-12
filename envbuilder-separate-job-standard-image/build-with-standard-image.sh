#!/usr/bin/env bash
# Wrapper script to build devcontainer image using standard envbuilder image
# This uses the official ghcr.io/coder/envbuilder:latest image instead of a custom fork

set -euo pipefail

# Use the standard envbuilder image
export ENVBUILDER_IMAGE="ghcr.io/coder/envbuilder:latest"

# Call the main build script
exec "$(dirname "$0")/../envbuilder-separate-job-build-devworkspace-image/build-image-envbuilder-and-create-dw.sh" "$@"
