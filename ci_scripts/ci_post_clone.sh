#!/bin/sh
# Xcode Cloud: restore resources kept out of the public repository. Builds
# stop here when the VIME_RESOURCE_KEY secret is missing or wrong.
set -eu
cd "${CI_PRIMARY_REPOSITORY_PATH:-$(dirname "$0")/..}"
swift Scripts/seal_resource.swift open \
    ci_scripts/LearningExclusions.sealed Shared/Resources/LearningExclusions.bin
