# VectorCraft Android localization and fonts

## UI language

The Android shell forwards the device's preferred BCP 47 locale to
`vectorcraft-ui-egui` before constructing the UI. The upstream localization registry currently
uses embedded `*.tsv` catalogs (not Fluent `.ftl` files). It already includes English fallback,
Simplified Chinese (`zh-hans`), Traditional Chinese (`zh-hant`), and other languages.

Catalogs support command-ID translations through rows whose context is `@id`; those keys are
stable identifiers, not translated labels. The UI also retains source-text lookups for legacy and
non-command labels, so a full migration of every UI literal to stable IDs must be done in the
upstream `storytold/vectorcraft` `crates/ui-egui` crate and its catalog tests. This Android-side
change intentionally does not fork or rewrite upstream UI sources.

The UI's existing `interfaceLanguage` preference remains authoritative when set explicitly;
automatic/system language selection uses the Android device locale.

## Font fallback

The native shell appends installed Android Noto/Droid font faces after VectorCraft's theme fonts,
preserving the theme's preferred faces. It checks CJK (Simplified/Traditional Chinese, Japanese,
Korean), symbol, Arabic, Thai, Devanagari and Hebrew candidates. Font availability varies by Android
image; only faces present on that device are loaded, and the app logs each loaded fallback. This
uses system font files instead of bundling binary font assets, avoiding duplicate APK payload and
keeping each system face under its platform's font licensing/attribution.
