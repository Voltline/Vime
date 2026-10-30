# Vime

[简体中文](README.md) | **English** | [日本語](README.ja.md) | [한국어](README.ko.md)

![Platform](https://img.shields.io/badge/platform-iOS%2018%2B-blue) ![Swift](https://img.shields.io/badge/Swift-UIKit%20%2B%20SwiftUI-orange) ![License](https://img.shields.io/badge/license-GPL--3.0--or--later-green)

Vime is a fully offline Japanese keyboard for iOS. It offers a romaji QWERTY layout and a 12-key kana pad, and switches between hiragana, katakana and English at any time. Kana-kanji conversion is built on the [azooKey](https://github.com/azooKey/AzooKeyKanaKanjiConverter) dictionary engine. A small on-device Core ML language model reranks the candidates and suggests the next word after you commit text. Conversion, correction, learning and suggestions all run on your device, and nothing you type is uploaded.

The companion app handles setup, typing practice, appearance and settings. The keyboard extension works in any app that allows third-party keyboards.

## Highlights

### Input

- **Two Japanese layouts**: full romaji QWERTY, or a 12-key kana pad. On the pad, tap for the あ-column kana and flick left, up, right or down for the others; tapping the same key repeatedly cycles through its kana (toggle input). The pad has `↶` (step back), `゛゜小` (voiced / semi-voiced / small) and `→` (end the toggle) keys, plus a two-row 確定 key that is easy to hit.
- **Instant kana draft**: kana appear as you type, and unfinished consonants stay as romaji. Conversion and predictions update in the background without blocking input.
- **Direct English input** with a one-tap Japanese/English switch and word completion in the candidate bar; auto-capitalization and the double-space period can be turned on in Settings. The number page can be a 3×3 pad or a full row layout.
- Move the cursor by dragging after a long press on the space bar, or by swiping across the keys; swipe up on a letter to enter its symbol.
- Double-tap Shift for caps lock. On an iPhone in portrait, the **one-handed keyboard** moves the keys to the left or right.

### Conversion and candidates

- **Whole-sentence and segmented conversion**: expand the candidates and use `−` / `+` to resize the first segment. After you confirm it, the rest keeps converting, and only confirmed text is written to the document.
- **Undo a conversion**: right after confirming a conversion, tap ↩ at the start of the candidate bar to return to its reading and choose again; a setting makes backspace do the same.
- **Smart ranking**: azooKey generates the candidates, and a local language model (INT8, CPU only) rescores them using the preceding text. Plain dictionary ranking is also available.
- **Next-word suggestions**: after you commit text, the idle candidate bar shows likely next words; tap one to keep going.
- **Correction candidates**: neighboring-key slips, similar sounds and a limited set of misreadings appear as candidates and are only applied when you pick them.
- **Format candidates**: half-width katakana (ｶﾞｯｺｳ) and full-width alphanumerics (ａｂｃ１２３).

### Productivity

- **User dictionary and phrase shortcuts**, with JSON import and export (up to 1,024 entries); your iOS text replacements work too.
- **Clipboard suggestions** (off by default): newly copied text appears in the candidate bar, and the last 24 hours of history stay on the device only.
- **Calculator on the number page**: typing `1+1` offers `2` and `1+1=2`.
- **Auto-paired brackets**: `()`, `（）`, `「」` and more, with the cursor placed between them.
- Categorized symbols, emoji and kaomoji; the symbol column on the number page is customizable.

### Personalization

- Built-in themes plus custom skins with your own background, key images and colors, shared as `.vimeskin` files.
- Drag to resize the keyboard; key sounds and continuously adjustable haptic strength.
- Learns your word choices on the device, and the learning can be cleared at any time.

### Companion app

- **Three-step setup**: add the keyboard, allow full access and switch to Vime; once done, the app opens the typing practice.
- **Typing practice**: type a sample sentence, and correct characters turn blue as you go.
- A status card in Settings shows whether the keyboard is working, which model version is loaded and how much it has learned.
- The interface is available in Simplified Chinese, Traditional Chinese, Japanese, English and Korean.

## Installation

Requires iOS 18 or later and an Xcode version that supports the project's SDK.

1. Open [Vime.xcodeproj](Vime.xcodeproj) in Xcode and select the `Vime` scheme. The first build resolves the pinned SwiftPM dependencies; model and tokenizer resources are already in the repository.
2. Before installing on a device, set up signing for the app and the `VimeKeyboard` extension. Both must share the same App Group (currently `group.com.Voltline.Vime`). See the [development guide](Docs/Development.md) (in Chinese).
3. Run the app and follow the setup on the home screen, or add Vime manually under Settings → General → Keyboard → Keyboards → Add New Keyboard.
4. In any text field, long-press the globe key and choose "Vime 日本語".

Basic offline typing works without Allow Full Access. Key sounds and haptics, settings shared between the app and keyboard, custom skins, user dictionary sync and clipboard suggestions require it. After changing settings, switch to another keyboard and back so the extension reloads them.

## Basic operations

| Action | Result |
| --- | --- |
| Type romaji | Kana appear immediately; unfinished consonants stay as romaji |
| Kana pad tap / flick | Tap for the あ-column kana, flick for the others; repeat taps cycle through the key |
| `↶` / `゛゜小` / `→` | Step back in the cycle / toggle voiced, semi-voiced and small forms / end the cycle so the same key starts a new kana |
| Space | Start converting; press again for the next candidate |
| Tap a candidate | Commit it; with segments, the rest stays in conversion |
| Expand → `−` / `+` / whole sentence | Resize the first segment or return to the whole sentence; scroll for more |
| Return / 確定 | Commit the selected candidate or the kana as typed; with nothing composed, perform the host app's return action |
| Delete / hold Delete | Delete one character / keep deleting |
| `あ` / `ア`, language key | Switch hiragana/katakana, or Japanese/English |
| Swipe up on a letter, swipe across keys, drag on space | Enter a symbol, move the cursor |
| Number key, emoji key | Open the number page, symbols or emoji |
| Vime logo (top left) | Quick settings: clipboard history, sound and haptics, number layout |

Candidate quality depends on the dictionary, the context and the lookup time budget, so not every word or typo will get an ideal result. Chinese input and a macOS version are not available.

## Privacy

- Conversion, correction, ranking, suggestions and learning all happen on the device. Vime contains no networking code and never uploads what you type or copy.
- Learning data, the user dictionary and skins live in the shared App Group container; clipboard history is excluded from system backups.
- See the full [privacy policy](Docs/Guides/Privacy.en.md) (also in [日本語](Docs/Guides/Privacy.ja.md), [简体中文](Docs/Guides/Privacy.md), [繁體中文](Docs/Guides/Privacy.zh-Hant.md) and [한국어](Docs/Guides/Privacy.ko.md)).

## Project layout

| Folder | Contents |
| --- | --- |
| `Vime/` | Companion app (SwiftUI): home, setup, customization, settings and about |
| `Keyboard/` | Keyboard extension entry point, `KeyboardViewController` |
| `Shared/` | Code shared by the app and extension: input session, candidate engine, language model, keyboard UI, preferences and resources |
| `Tests/` | XCTest suites for the engine, candidates, session, UI components and the extension |
| `Dependencies/` | Bundled SentencePiece tokenizer |
| `Scripts/` | Resource generation, model and app resource validation, reproducible test runs |
| `Docs/` | Guides, development workflow and architecture notes (in Chinese) |

## Development

```bash
python3 Scripts/validate_model_resources.py
```

```bash
python3 Scripts/validate_app_resources.py
```

The first validates model manifests, tokenizers and SHA256 checksums. The second checks license notices, privacy policies and that the localization catalog is complete. UI strings live in `Shared/Resources/Localizable.xcstrings`, and new strings need all five languages. The full test workflow (`Scripts/verify_review.sh`), how to verify the real keyboard extension and troubleshooting tips are in the [development guide](Docs/Development.md).

## Documentation

The detailed documentation is written in Chinese.

- [Documentation index](Docs/README.md)
- Usage: [App settings](Docs/Guides/AppSettings.md) · [Custom skins](Docs/Guides/CustomSkins.md) · [User dictionary](Docs/Guides/UserDictionary.md)
- Development: [Project layout](Docs/ProjectLayout.md) · [Development and verification](Docs/Development.md) · [Japanese model](Docs/Models/JapaneseModel.md)
- Architecture: [Input pipeline](Docs/Architecture/InputPipeline.md) · [Candidates and suggestions](Docs/Architecture/Candidates.md) · [Learning and personalization](Docs/Architecture/Personalization.md) · [Input backends](Docs/Architecture/InputBackends.md) · [Emoji rendering](Docs/Architecture/EmojiRendering.md)

## License and acknowledgements

Vime is released under [GPL-3.0-or-later](LICENSE), with an additional permission under GPLv3 section 7 that allows distribution through app stores such as the App Store as long as the Corresponding Source is offered; see [LICENSE-EXCEPTION](LICENSE-EXCEPTION). Versions before 2026-10-22 were released under GPL-2.0-only. The bundled [VimeML](https://github.com/Voltline/VimeML) Japanese model uses the same license; its training data attribution is in the third-party notices. Kana-kanji conversion uses [AzooKeyKanaKanjiConverter](https://github.com/azooKey/AzooKeyKanaKanjiConverter), and tokenization uses [SentencePiece](https://github.com/google/sentencepiece). Licenses, acknowledgements and sources for third-party code and data are in [ThirdPartyNotices.txt](Shared/Resources/ThirdPartyNotices.txt), the [SentencePiece LICENSE](Dependencies/VimeSentencePiece/LICENSE) and the [language resource sources](Shared/Resources/LanguageResourceSources.json). The full texts are also available in the app under Settings → About Vime → Open Source Licenses.
