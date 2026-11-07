# Upstream sources

Copied by `Scripts/vendor_rime.py`; do not edit files under `Sources/CRime/vendor`.
Three changes to upstream code are applied by the script: a learning filter
hook in `librime/src/rime/gear/memory.cc`; in
`librime/src/rime/gear/script_translator.cc`, how spelling corrections rank
(`patch_corrections`); and in `librime/src/rime/dict/dictionary.cc`, spelling
penalties past a phrase's third syllable (`patch_extra_code_credibility`).

| Project | Commit | License |
| --- | --- | --- |
| [librime](https://github.com/rime/librime) | `2bae6b59b5ebbf2a8af7ffae5b22fbf090f91841 2026-11-05` | BSD-3-Clause |
| [yaml-cpp](https://github.com/jbeder/yaml-cpp) | `56e3bb550c91fd7005566f19c079cb7a503223cf 2026-02-04` | MIT |
| [leveldb](https://github.com/google/leveldb) | `bb74ef739973a70ca9f0d90788a1da89b788c0ad 2026-10-08` | BSD-3-Clause |
| [marisa-trie](https://github.com/s-yata/marisa-trie) | `3e87d53b78e15f2f43783d5e376561a8c9722051 2025-07-20` | BSD-2-Clause or LGPL-2.1+ |
| [OpenCC](https://github.com/BYVoid/OpenCC) | `025f371dc76b598d77384fbdab90c937471844d8 2026-08-22` | Apache-2.0 |
| [Boost](https://www.boost.org) headers (1025 files) | 1.90 | BSL-1.0 |

## Dictionary data

`Scripts/build_rime_data.sh` generates the Chinese and English dictionaries
with `Scripts/build_rime_dicts.py` and compiles them into
`Shared/Resources/RimeData.bundle`, whose `SOURCE.txt` records the same pins.
The generated data contains CC BY-SA 4.0 material and is distributed under
CC BY-SA 4.0.

| Source | Pin | License | Used for |
| --- | --- | --- | --- |
| [mozillazg/pinyin-data](https://github.com/mozillazg/pinyin-data) | `fe29ad32bdf352b31a02b9936e537f575432e9a6 2026-11-01` | MIT | readings of the 8105 standard characters |
| [mozillazg/phrase-pinyin-data](https://github.com/mozillazg/phrase-pinyin-data) | `4afa3226ce53c9138b939e83c3bb294dbe0da511 2026-11-01` | MIT | word readings (`pinyin.txt`) |
| [CC-CEDICT](https://cc-cedict.org) via phrase-pinyin-data `cc_cedict.txt` | same commit | CC BY-SA 4.0 | more words and readings |
| [fxsjy/jieba](https://github.com/fxsjy/jieba) `dict.txt` | `67fa2e36e72f69d9134b8a1037b83fbb070b9775 2020-02-15` | MIT | Chinese word counts |
| [rspeer/wordfreq](https://github.com/rspeer/wordfreq) data | `912caf64b657478d1dff1138efdc078947d54bb1 2025-01-04` | CC BY-SA 4.0 | Chinese and English word frequencies |
| [en-wl/wordlist](https://github.com/en-wl/wordlist) (ESDB, formerly SCOWL) | `1e5b7d3a72f47a71da5d28686c1dd4b397178485 2026-06-24` | MIT-like | English words up to size 70 and their casing |
| [Unihan](https://www.unicode.org/Public/18.0.0/ucd/Unihan.zip) `kHanyuPinlu` | Unicode 18.0.0, SHA-256 `4c93ea9c…` | Unicode License V3 | how often each reading of a character occurs |
| [Tatoeba](https://tatoeba.org) Mandarin sentences | export of 2026-11-07, SHA-256 `262a48ca…` | CC BY 2.0 FR | common short phrases such as 好的, counted into `Scripts/rime_collocations.txt` because Tatoeba keeps no old exports |
