"""Keep the Sparkle tools used by the release workflow in step with the app's Sparkle package."""

import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ROOT / ".github/workflows/release.yml"
RESOLVED = ROOT / "Platforms/macOS/FoldGit.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
PROJECT = ROOT / "Platforms/macOS/project.yml"


def workflow_value(name):
    match = re.search(rf"^\s*{name}:\s*['\"]?([^'\"\s#]+)", WORKFLOW.read_text(encoding="utf-8"), re.MULTILINE)
    if match is None:
        raise AssertionError(f"{name} is missing from {WORKFLOW.relative_to(ROOT)}")
    return match.group(1)


class SparkleToolsTests(unittest.TestCase):
    def test_tools_version_matches_resolved_sparkle_package(self):
        pins = json.loads(RESOLVED.read_text(encoding="utf-8"))["pins"]
        resolved = next(pin["state"]["version"] for pin in pins if pin["identity"] == "sparkle")
        self.assertEqual(workflow_value("SPARKLE_TOOLS_VERSION"), resolved,
                         "Update SPARKLE_TOOLS_VERSION and SPARKLE_TOOLS_SHA256 in release.yml with the Sparkle package.")

    def test_tools_version_matches_exact_project_requirement(self):
        match = re.search(r"^  Sparkle:\n(?:    .*\n)*?    exactVersion:\s*['\"]?([^'\"\s]+)",
                          PROJECT.read_text(encoding="utf-8"), re.MULTILINE)
        if match is None:
            self.skipTest("project.yml does not pin an exact Sparkle version")
        self.assertEqual(workflow_value("SPARKLE_TOOLS_VERSION"), match.group(1))

    def test_tools_checksum_is_a_sha256_digest(self):
        self.assertRegex(workflow_value("SPARKLE_TOOLS_SHA256"), r"^[0-9a-f]{64}$")


if __name__ == "__main__":
    unittest.main()
