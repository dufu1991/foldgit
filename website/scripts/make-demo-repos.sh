#!/bin/bash
# Builds fictional demo repositories for FoldGit marketing screenshots.
# Usage: website/scripts/make-demo-repos.sh <output-dir>
set -euo pipefail

out="${1:?usage: make-demo-repos.sh <output-dir>}"
if [ -e "$out" ]; then
  echo "Output directory already exists: $out" >&2
  exit 1
fi
mkdir -p "$out"
out="$(cd "$out" && pwd)"

# Fictional people only; example.com addresses have no Gravatar, so the app shows initials.
authors=(
  "Mira Chen|mira@example.com"
  "Leo Hartmann|leo@example.com"
  "Aiko Tanaka|aiko@example.com"
  "Sam Rivera|sam@example.com"
  "Noa Levi|noa@example.com"
)

now=$(date +%s)
hours_ago=150

# commit <author-index> <message> — commits whatever is staged, moving the clock forward.
commit() {
  local who="${authors[$1]}"
  local name="${who%%|*}" email="${who##*|}"
  hours_ago=$((hours_ago - (RANDOM % 7 + 2)))
  [ "$hours_ago" -lt 1 ] && hours_ago=1
  local when=$((now - hours_ago * 3600))
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_AUTHOR_DATE="@$when" \
  GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" GIT_COMMITTER_DATE="@$when" \
    git commit -q --no-verify -m "$2"
}

merge() {
  local who="${authors[$1]}"
  local name="${who%%|*}" email="${who##*|}"
  hours_ago=$((hours_ago - (RANDOM % 3 + 1)))
  local when=$((now - hours_ago * 3600))
  GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$email" GIT_AUTHOR_DATE="@$when" \
  GIT_COMMITTER_NAME="$name" GIT_COMMITTER_EMAIL="$email" GIT_COMMITTER_DATE="@$when" \
    git merge -q --no-ff --no-edit -m "$3" "$2"
}

init_repo() {
  mkdir -p "$out/$1"
  cd "$out/$1"
  git init -q -b main
  git config user.name "Mira Chen"
  git config user.email "mira@example.com"
  git config commit.gpgsign false
  git config tag.gpgsign false
}

write() { mkdir -p "$(dirname "$1")"; cat > "$1"; }

# ---------------------------------------------------------------- aurora-ui
init_repo aurora-ui

write README.md <<'EOF'
# Aurora UI

A small set of SwiftUI components for calm, glassy interfaces.
EOF
write Package.swift <<'EOF'
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AuroraUI",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [.library(name: "AuroraUI", targets: ["AuroraUI"])],
    targets: [.target(name: "AuroraUI")]
)
EOF
git add -A; commit 0 "Initial commit"

write Sources/AuroraUI/GlassCard.swift <<'EOF'
import SwiftUI

public struct GlassCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        content
            .padding(16)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: 16))
    }
}
EOF
git add -A; commit 0 "Add GlassCard component"

write Sources/AuroraUI/Theme.swift <<'EOF'
import SwiftUI

public enum Theme {
    public static let cornerRadius: CGFloat = 16
    public static let spacing: CGFloat = 12
    public static let accent = Color.indigo
}
EOF
git add -A; commit 1 "Introduce shared theme constants"

git switch -q -c feature/toolbar
write Sources/AuroraUI/FloatingToolbar.swift <<'EOF'
import SwiftUI

public struct FloatingToolbar<Items: View>: View {
    private let items: Items

    public init(@ViewBuilder items: () -> Items) {
        self.items = items()
    }

    public var body: some View {
        HStack(spacing: Theme.spacing) { items }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.regularMaterial, in: .capsule)
            .shadow(color: .black.opacity(0.12), radius: 12, y: 6)
    }
}
EOF
git add -A; commit 2 "Add FloatingToolbar with capsule background"
sed -i '' 's/radius: 12, y: 6/radius: 18, y: 8/' Sources/AuroraUI/FloatingToolbar.swift
git add -A; commit 2 "Soften toolbar shadow"

git switch -q main
write Sources/AuroraUI/GlassCard.swift <<'EOF'
import SwiftUI

public struct GlassCard<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = Theme.cornerRadius, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(16)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.white.opacity(0.18))
            }
    }
}
EOF
git add -A; commit 0 "Let GlassCard customize its corner radius"
merge 0 feature/toolbar "Merge branch 'feature/toolbar'"
git tag -a v0.1.0 -m "First preview" >/dev/null

git switch -q -c fix/dark-mode
sed -i '' 's/strokeBorder(.white.opacity(0.18))/strokeBorder(.primary.opacity(0.12))/' Sources/AuroraUI/GlassCard.swift
git add -A; commit 3 "Use adaptive stroke color in dark mode"
git switch -q main
write Sources/AuroraUI/Badge.swift <<'EOF'
import SwiftUI

public struct Badge: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.accent.opacity(0.15), in: .capsule)
            .foregroundStyle(Theme.accent)
    }
}
EOF
git add -A; commit 1 "Add Badge view"
merge 3 fix/dark-mode "Merge branch 'fix/dark-mode'"

write CHANGELOG.md <<'EOF'
# Changelog

## 0.2.0
- FloatingToolbar
- Badge
- Adaptive GlassCard stroke

## 0.1.0
- GlassCard
EOF
git add -A; commit 0 "Update changelog for 0.2.0"
git tag -a v0.2.0 -m "Toolbar and badges" >/dev/null

git switch -q -c feature/segmented-control
write Sources/AuroraUI/SegmentedControl.swift <<'EOF'
import SwiftUI

public struct SegmentedControl<Value: Hashable>: View {
    @Binding var selection: Value
    let options: [(Value, String)]

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.0) { value, title in
                Button(title) { selection = value }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(selection == value ? AnyShapeStyle(.thickMaterial) : AnyShapeStyle(.clear), in: .capsule)
            }
        }
        .padding(3)
        .background(.ultraThinMaterial, in: .capsule)
    }
}
EOF
git add -A; commit 4 "Draft SegmentedControl"
git switch -q main

# Work in progress: staged + unstaged edits for the changes screen.
write Sources/AuroraUI/Theme.swift <<'EOF'
import SwiftUI

public enum Theme {
    public static let cornerRadius: CGFloat = 18
    public static let spacing: CGFloat = 12
    public static let accent = Color.indigo
    public static let glassTint = Color.white.opacity(0.08)

    /// Spring used by every interactive component.
    public static let spring = Animation.spring(response: 0.42, dampingFraction: 0.82)
}
EOF
git add Sources/AuroraUI/Theme.swift
write Tests/AuroraUITests/ThemeTests.swift <<'EOF'
import Testing
@testable import AuroraUI

@Test func sharedSpacingIsPositive() {
    #expect(Theme.spacing > 0)
}
EOF
git add Tests/AuroraUITests/ThemeTests.swift
write Sources/AuroraUI/GlassCard.swift <<'EOF'
import SwiftUI

public struct GlassCard<Content: View>: View {
    private let content: Content
    private let cornerRadius: CGFloat
    @State private var isHovered = false

    public init(cornerRadius: CGFloat = Theme.cornerRadius, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    public var body: some View {
        content
            .padding(16)
            .background(.ultraThinMaterial, in: .rect(cornerRadius: cornerRadius))
            .background(Theme.glassTint, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(.primary.opacity(isHovered ? 0.2 : 0.12))
            }
            .scaleEffect(isHovered ? 1.01 : 1)
            .animation(Theme.spring, value: isHovered)
            .onHover { isHovered = $0 }
    }
}
EOF
write README.md <<'EOF'
# Aurora UI

A small set of SwiftUI components for calm, glassy interfaces.

## Components

- `GlassCard` — translucent container with a hairline border
- `FloatingToolbar` — capsule toolbar that floats above content
- `Badge` — compact status label
EOF
write Sources/AuroraUI/Badge.swift <<'EOF'
import SwiftUI

public struct Badge: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, Theme.spacing)
            .padding(.vertical, 4)
            .background(Theme.accent.opacity(0.15), in: .capsule)
            .foregroundStyle(Theme.accent)
            .accessibilityLabel(text)
    }
}
EOF

# ---------------------------------------------------------------- tide-api
hours_ago=110
init_repo tide-api

write package.json <<'EOF'
{
  "name": "tide-api",
  "version": "1.0.0",
  "type": "module",
  "scripts": { "dev": "tsx watch src/server.ts", "test": "vitest" }
}
EOF
write src/server.ts <<'EOF'
import { createServer } from "node:http";
import { router } from "./router.js";

const port = Number(process.env.PORT ?? 8080);

createServer(router).listen(port, () => {
  console.log(`tide-api listening on :${port}`);
});
EOF
write src/router.ts <<'EOF'
import type { IncomingMessage, ServerResponse } from "node:http";

export function router(req: IncomingMessage, res: ServerResponse) {
  if (req.url === "/health") {
    res.writeHead(200, { "content-type": "application/json" });
    res.end(JSON.stringify({ ok: true }));
    return;
  }
  res.writeHead(404).end();
}
EOF
git add -A; commit 1 "Bootstrap HTTP server"

write src/tides.ts <<'EOF'
export interface TideReading {
  station: string;
  height: number;
  at: Date;
}

export function nextHighTide(readings: TideReading[]): TideReading | undefined {
  return readings
    .filter((r) => r.at > new Date())
    .sort((a, b) => b.height - a.height)[0];
}
EOF
git add -A; commit 1 "Add tide reading model"

git switch -q -c feature/cache
write src/cache.ts <<'EOF'
export class TTLCache<V> {
  private store = new Map<string, { value: V; expires: number }>();

  constructor(private ttl: number) {}

  get(key: string): V | undefined {
    const hit = this.store.get(key);
    if (!hit || hit.expires < Date.now()) return undefined;
    return hit.value;
  }

  set(key: string, value: V) {
    this.store.set(key, { value, expires: Date.now() + this.ttl });
  }
}
EOF
git add -A; commit 3 "Add TTL cache for station lookups"
git switch -q main
write src/router.ts <<'EOF'
import type { IncomingMessage, ServerResponse } from "node:http";
import { nextHighTide } from "./tides.js";
import { loadReadings } from "./stations.js";

export async function router(req: IncomingMessage, res: ServerResponse) {
  const url = new URL(req.url ?? "/", "http://localhost");

  if (url.pathname === "/health") {
    return json(res, 200, { ok: true });
  }

  if (url.pathname.startsWith("/stations/")) {
    const id = url.pathname.split("/")[2];
    const readings = await loadReadings(id);
    return json(res, 200, { station: id, next: nextHighTide(readings) });
  }

  res.writeHead(404).end();
}

function json(res: ServerResponse, status: number, body: unknown) {
  res.writeHead(status, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}
EOF
write src/stations.ts <<'EOF'
import type { TideReading } from "./tides.js";

export async function loadReadings(station: string): Promise<TideReading[]> {
  const response = await fetch(`https://tides.example.com/v1/${station}`);
  if (!response.ok) throw new Error(`Station ${station} unavailable`);
  return response.json();
}
EOF
git add -A; commit 4 "Expose /stations/:id endpoint"
merge 1 feature/cache "Merge branch 'feature/cache'"
git tag -a v1.0.0 -m "Public beta" >/dev/null
write src/stations.ts <<'EOF'
import type { TideReading } from "./tides.js";
import { TTLCache } from "./cache.js";

const cache = new TTLCache<TideReading[]>(5 * 60_000);

export async function loadReadings(station: string): Promise<TideReading[]> {
  const cached = cache.get(station);
  if (cached) return cached;

  const response = await fetch(`https://tides.example.com/v1/${station}`);
  if (!response.ok) throw new Error(`Station ${station} unavailable`);
  const readings: TideReading[] = await response.json();
  cache.set(station, readings);
  return readings;
}
EOF
git add -A; commit 3 "Cache station readings for five minutes"
write src/tides.ts <<'EOF'
export interface TideReading {
  station: string;
  height: number;
  at: Date;
}

export function nextHighTide(readings: TideReading[], now = new Date()): TideReading | undefined {
  return readings
    .filter((r) => new Date(r.at) > now)
    .sort((a, b) => b.height - a.height)[0];
}
EOF
git add -A; commit 1 "Make nextHighTide testable with an injected clock"
git switch -q -c release/1.1
sed -i '' 's/"version": "1.0.0"/"version": "1.1.0"/' package.json
git add -A; commit 4 "Bump version to 1.1.0"
git switch -q main
# A stash for the stash screen.
echo 'export const DEFAULT_STATION = "harbor-01";' > src/config.ts
git add src/config.ts
git stash push -q -m "WIP: default station config"
# A linked worktree for the worktree screen.
git worktree add -q "$out/tide-api-release" release/1.1

# ---------------------------------------------------------------- pebble-notes
hours_ago=80
init_repo pebble-notes

write README.md <<'EOF'
# Pebble Notes

Tiny, offline-first notes for macOS.
EOF
git add -A; commit 2 "Initial commit"
write Sources/Note.swift <<'EOF'
import Foundation

struct Note: Identifiable, Codable, Hashable {
    let id: UUID
    var title: String
    var body: String
    var updatedAt: Date
}
EOF
git add -A; commit 2 "Add Note model"
write Sources/NoteStore.swift <<'EOF'
import Foundation
import Observation

@Observable
final class NoteStore {
    private(set) var notes: [Note] = []

    func add(title: String) {
        notes.insert(Note(id: UUID(), title: title, body: "", updatedAt: .now), at: 0)
    }

    func delete(_ note: Note) {
        notes.removeAll { $0.id == note.id }
    }
}
EOF
git add -A; commit 0 "Add observable NoteStore"
git switch -q -c feature/search
write Sources/NoteStore+Search.swift <<'EOF'
import Foundation

extension NoteStore {
    func search(_ query: String) -> [Note] {
        guard !query.isEmpty else { return notes }
        return notes.filter {
            $0.title.localizedCaseInsensitiveContains(query) ||
            $0.body.localizedCaseInsensitiveContains(query)
        }
    }
}
EOF
git add -A; commit 2 "Search notes by title and body"
git switch -q main
write Sources/ContentView.swift <<'EOF'
import SwiftUI

struct ContentView: View {
    @State private var store = NoteStore()

    var body: some View {
        NavigationSplitView {
            List(store.notes) { note in
                Text(note.title)
            }
        } detail: {
            Text("Select a note")
        }
    }
}
EOF
git add -A; commit 4 "Add split view shell"
merge 2 feature/search "Merge branch 'feature/search'"
git tag -a v0.3.0 -m "Search" >/dev/null
printf '\nSync with iCloud is planned for 0.4.\n' >> README.md

# ---------------------------------------------------------------- harbor-docs
hours_ago=30
init_repo harbor-docs
write index.md <<'EOF'
# Harbor Docs

Guides for the Harbor design system.
EOF
git add -A; commit 3 "Initial docs skeleton"
write guides/colors.md <<'EOF'
# Colors

Use semantic colors; never hard-code hex values in components.
EOF
git add -A; commit 3 "Add color guide"
write guides/motion.md <<'EOF'
# Motion

Prefer springs over linear curves. Keep durations under 400 ms.
EOF
git add -A; commit 1 "Add motion guide"

echo "Demo repositories created in $out"
