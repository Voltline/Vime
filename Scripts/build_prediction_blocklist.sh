#!/bin/sh
# Rebuilds the prediction blocklists from the local word lists:
#   Scripts/prediction_blocklist.txt          -> PredictionBlocklist.bin (Chinese)
#   Scripts/prediction_blocklist_japanese.txt -> PredictionBlocklistJapanese.bin
# Both use Scripts/prediction_blocklist_allowed.txt (everyday words that cut
# through short matches). No list and no .bin is committed; seal each .bin for
# Xcode Cloud afterwards:
#     VIME_RESOURCE_KEY=… swift Scripts/seal_resource.swift seal \
#         Shared/Resources/PredictionBlocklist.bin ci_scripts/PredictionBlocklist.sealed
#     VIME_RESOURCE_KEY=… swift Scripts/seal_resource.swift seal \
#         Shared/Resources/PredictionBlocklistJapanese.bin ci_scripts/PredictionBlocklistJapanese.sealed
set -eu
cd "$(dirname "$0")/.."
python3 Scripts/build_learning_exclusions.py Scripts/prediction_blocklist.txt \
    --allowed Scripts/prediction_blocklist_allowed.txt \
    --output Shared/Resources/PredictionBlocklist.bin
python3 Scripts/build_learning_exclusions.py Scripts/prediction_blocklist_japanese.txt \
    --allowed Scripts/prediction_blocklist_allowed.txt \
    --output Shared/Resources/PredictionBlocklistJapanese.bin
