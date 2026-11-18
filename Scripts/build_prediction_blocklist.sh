#!/bin/sh
# Rebuilds Shared/Resources/PredictionBlocklist.bin from the local word lists
# Scripts/prediction_blocklist.txt and Scripts/prediction_blocklist_allowed.txt
# (everyday words that cut through short matches). Neither list nor the .bin is
# committed; seal the .bin for Xcode Cloud afterwards:
#     VIME_RESOURCE_KEY=… swift Scripts/seal_resource.swift seal \
#         Shared/Resources/PredictionBlocklist.bin ci_scripts/PredictionBlocklist.sealed
set -eu
cd "$(dirname "$0")/.."
python3 Scripts/build_learning_exclusions.py Scripts/prediction_blocklist.txt \
    --allowed Scripts/prediction_blocklist_allowed.txt \
    --output Shared/Resources/PredictionBlocklist.bin
