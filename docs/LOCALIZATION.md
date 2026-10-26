# Interface localization

FoldGit stores each language independently in a native macOS localization folder:

```text
Platforms/macOS/Resources/
├── en.lproj/
├── zh-Hans.lproj/
├── zh-Hant.lproj/
├── ja.lproj/
├── ko.lproj/
├── ru.lproj/
├── fr.lproj/
└── es.lproj/
```

Each folder contains `Localizable.strings` for ordinary interface text and
`Localizable.stringsdict` for counts with language-specific plural forms. These
files are the editable sources; there is no combined catalog or generation step.
Xcode bundles them using two localized variant groups in the app target.

Supported languages are English (`en`), Simplified Chinese (`zh-Hans`), Traditional
Chinese (`zh-Hant`), Japanese (`ja`), Korean (`ko`), Russian (`ru`), French (`fr`),
and Spanish (`es`). The interface follows the app language selected in macOS
System Settings → General → Language & Region → Applications. Relaunch the app
after changing its language. The General settings pane also lets users select an app language. Selecting a different language prompts users to restart now or later. A restart button remains visible until the app relaunches or the user selects the language used at launch. Restarting waits for the existing process to exit before reopening the same app path.

## Adding or changing translations

1. Edit the appropriate `Platforms/macOS/Resources/<language>.lproj/Localizable.strings`
   file. It uses standard `"English key" = "Translation";` entries in UTF-8.
2. To add a language, create its `.lproj` folder with both files, add its code to `Platforms/macOS/project.yml` under `knownRegions`, and run `xcodegen generate --spec Platforms/macOS/project.yml`. Keep all keys complete.
3. Preserve interpolation placeholders such as `%@` and `%lld`. Translate the
   whole phrase so word order can change; do not concatenate translated words.
4. Edit count translations in `Localizable.stringsdict`. Preserve the `count`
   variable and `lld` argument type. Provide the plural categories required by
   the language, including Russian `one`, `few`, `many`, and `other` forms.
5. Update the supported-language checks in `Scripts/validate-localizations.py`
   and the resource lookup cases in `Platforms/macOS/Tests/Features/LocalizationTests.swift`.

SwiftUI literals such as `Text("Commit")` and `.help("Fetch")` are localized by
SwiftUI. Use `String(localized:)` for text returned from model properties, passed
through a plain `String` parameter, or selected conditionally. Reusable view
properties that accept localization keys should use `LocalizedStringKey`.

Repository content, branch names, tags, paths, commit messages, and Git's original
diagnostic output remain unchanged. The application-owned error heading is
localized. Git's short statistics are formatted for display separately from
command parsing. AI-generated output has its own existing language behavior and
is independent of interface translations.

## Terminology

Keep stage/unstage distinct from stash. Simplified Chinese uses 暂存 / 取消暂存
and 贮藏; Traditional Chinese uses 暫存 / 取消暫存 and 儲藏. Japanese uses
ステージ and スタッシュ; Korean uses 스테이징 and 스태시. French uses
indexer / désindexer, Russian uses добавить в индекс / убрать из индекса, and
Spanish uses preparar / retirar de preparación. Git reference syntax and
command identifiers such as `origin` and `HEAD` are not translated.

## Validation

Validate all per-language files without building:

```sh
python3 Scripts/validate-localizations.py
find Resources -type f \( -name '*.strings' -o -name '*.stringsdict' \) \
  -exec plutil -lint {} +
```

After building, also check the exact keys emitted by the Swift compiler:

```sh
python3 Scripts/validate-localizations.py \
  --extracted-directory /tmp/FoldGit-build/Build/Intermediates.noindex/FoldGit.build
```

Build and run the focused tests using temporary local Git repositories:

```sh
xcodebuild test -project Platforms/macOS/FoldGit.xcodeproj -scheme FoldGit \
  -destination 'platform=macOS' -derivedDataPath /tmp/FoldGit-build \
  -only-testing:FoldGitTests/LocalizationTests \
  -testLanguage en -testRegion US
```

For localized sheet snapshots, prefix the command with
`TEST_RUNNER_LOCALIZATION_SNAPSHOT_DIRECTORY=/tmp/FoldGit-localization-snapshots`.
The tests cover resource inclusion, Russian plural selection, Chinese count word
order, and tag-sheet rendering in all supported languages.

## Layout review

Section headings and statistics can stack vertically. The change-action bar and
tag creation actions switch to vertical layouts when their labels do not fit.
Branch and tag forms align each label with its field in a Grid and use flexible
sheet widths. Summary bars reserve space for controls and grow vertically.

When reviewing new translations, check the main window at its minimum size,
branch creation and renaming, tag creation, the commit editor, the revision
comparison sheet, and tooltips. Russian, French, and Spanish are useful checks
for longer labels. Keep action labels readable; wrap text or change layout
before reducing font size. Use tooltips for complete repository paths.
