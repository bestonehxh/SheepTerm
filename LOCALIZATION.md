# Translating SheepTerm

All supported language translations are maintained together in:

```
SheepTerm/Localization/Localizable.xcstrings
```

This is an Xcode String Catalog (plain UTF-8 JSON). Download this file from the
repository to translate it, or open it in Xcode for a table of strings and
languages. Currently the catalog contains English (`en`, source language),
German (`de`), Spanish (`es`), French (`fr`), Brazilian Portuguese (`pt-BR`),
Russian (`ru`), Japanese (`ja`), Korean (`ko`) and Simplified Chinese (`zh-Hans`).
Terminal vocabulary in the newer languages follows Tabby's translations where they
overlap, and standard words follow macOS's own; corrections from native speakers
are welcome. Edit translations here; do not edit the built
app's `.lproj` files, which Xcode generates from the catalog.

For example, each source key has one entry for each translated language:

```json
"Cancel": {
  "localizations": {
    "en": { "stringUnit": { "state": "translated", "value": "Cancel" } },
    "zh-Hans": { "stringUnit": { "state": "translated", "value": "取消" } }
  }
}
```

To add another language, add it under the Xcode project's Info → Localizations,
then enter translations in this same catalog. With a text editor, add a locale
under `localizations` for each translated entry and register that locale in the
project's `knownRegions`, and add it to `AppLanguage` (its own name in
`nativeName`) so it appears in Settings. `./Tests/run.sh tests` fails until every
key is translated in every listed language with the English format specifiers. Preserve source keys, placeholders and plural forms.
Untranslated text falls back to English. Keep protocol names, device commands,
user host names and terminal output unchanged.

The catalog centralizes the strings already connected to localization APIs.
Translation coverage is still being expanded; some older runtime labels and
messages still need migration. New SwiftUI text should use literal localization
APIs; AppKit display text should use `String(localized:)`. Xcode's Product →
Export Localizations workflow collects new localizable strings and produces
translator bundles without maintaining duplicate hand-written `.strings` files.

Users choose a language in **Settings → General → Language → App Language**,
then quit and reopen SheepTerm. The choices are System Default and the nine
languages above. Adding a translation for another language also requires
adding its option to the in-app picker. Keyboard input is independent of the
interface language; Chinese input uses the macOS input source, and Chinese
terminal output must be UTF-8.
