"""
Release automation for Melcosoft.Releases. Python port of release.ps1 - same 23 steps,
same behavior. Run from anywhere; paths are resolved relative to this file's location
(Melcosoft.Releases) and its parent (repo root).
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

# Windows consoles often default stdout/stdin to a legacy codepage (e.g. cp1252), which
# raises UnicodeEncodeError the moment we print the Cyrillic half of release notes.
for _stream in (sys.stdout, sys.stderr, sys.stdin):
    try:
        _stream.reconfigure(encoding="utf-8")
    except Exception:
        pass

SCRIPT_DIR = Path(__file__).resolve().parent
RELEASES_REPO = SCRIPT_DIR
REPO_ROOT = SCRIPT_DIR.parent
LATEST_FILES = RELEASES_REPO / "latest_files"
LATEST_JSON_PATH = RELEASES_REPO / "latest.json"
RELEASE_MANIFEST_PATH = LATEST_FILES / "release_manifest.json"
FILE_MANIFEST_PATH = LATEST_FILES / "file_manifest.json"


# ---------- console helpers ----------

if os.name == "nt":
    os.system("")  # enables ANSI escape processing in classic Windows consoles


class Color:
    YELLOW = "\033[93m"
    GREEN = "\033[92m"
    CYAN = "\033[96m"
    GRAY = "\033[90m"
    RESET = "\033[0m"


def section(text: str) -> None:
    print(f"\n{Color.CYAN}== {text} =={Color.RESET}")


def warn(text: str) -> None:
    print(f"{Color.YELLOW}{text}{Color.RESET}")


def ok(text: str) -> None:
    print(f"{Color.GREEN}{text}{Color.RESET}")


def gray(text: str) -> None:
    print(f"{Color.GRAY}{text}{Color.RESET}")


def confirm(message: str) -> bool:
    resp = input(f"{message} (y/N): ").strip().lower()
    return resp in ("y", "yes")


def read_multiline(prompt: str) -> str:
    print(prompt)
    print("(Paste/type the text; finish with a line containing only: END)")
    lines: list[str] = []
    while True:
        line = input()
        if line == "END":
            break
        lines.append(line)
    return "\n".join(lines)


# ---------- file helpers ----------

def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def save_json(path: Path, obj: dict) -> None:
    text = json.dumps(obj, ensure_ascii=False, indent=2)
    path.write_text(text + "\n", encoding="utf-8")


def assert_path_exists(path: Path, description: str) -> None:
    if not path.exists():
        raise FileNotFoundError(f"{description} not found: {path}")


def copy_dir_mirror(source: Path, dest: Path) -> None:
    assert_path_exists(source, "Source directory")
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(source, dest)


def zip_dir_contents(source_dir: Path, dest_zip: Path) -> None:
    if dest_zip.exists():
        dest_zip.unlink()
    dest_zip.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(dest_zip, "w", zipfile.ZIP_DEFLATED) as zf:
        for file_path in source_dir.rglob("*"):
            if file_path.is_file():
                zf.write(file_path, file_path.relative_to(source_dir))


def git(repo_path: Path, *args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["git", "-C", str(repo_path), *args],
        capture_output=True, text=True, encoding="utf-8"
    )


def git_commit_push(repo_path: Path, label: str, message: str) -> None:
    section(f"{label} - git add / commit / push")

    r = subprocess.run(["git", "-C", str(repo_path), "add", "."])
    if r.returncode != 0:
        raise RuntimeError(f"git add failed in {repo_path}.")

    pending = git(repo_path, "status", "--porcelain", "--cached")
    if not pending.stdout.strip():
        print(f"Nothing to commit in {repo_path}, skipping commit/push.")
        return

    r = subprocess.run(["git", "-C", str(repo_path), "commit", "-m", message])
    if r.returncode != 0:
        raise RuntimeError(f"git commit failed in {repo_path}.")

    r = subprocess.run(["git", "-C", str(repo_path), "push"])
    if r.returncode != 0:
        raise RuntimeError(f"git push failed in {repo_path}. Commit succeeded locally - push manually once resolved.")

    ok(f"{label} pushed.")


# ---------- main ----------

def main() -> None:
    section("Melcosoft release script")
    print(f"Releases repo: {RELEASES_REPO}")
    print(f"Repo root:     {REPO_ROOT}")

    branch = git(RELEASES_REPO, "branch", "--show-current").stdout.strip()
    print(f"Current branch: {branch}")
    if branch != "main":
        if not confirm(f"Not on 'main' (currently '{branch}'). Continue anyway?"):
            print("Aborted.")
            sys.exit(1)

    latest = load_json(LATEST_JSON_PATH)
    release_manifest = load_json(RELEASE_MANIFEST_PATH)

    # ---------- 1-2: ask for release_notes / version ----------

    section("Step 1-2: release notes and version")
    gray("Current release_manifest.json release_notes:")
    gray(release_manifest.get("release_notes", ""))
    release_notes = read_multiline("Enter new release_notes:")

    gray(f"Current release_manifest.json version: {release_manifest.get('version', '')}")
    version = input("Enter new version: ").strip()
    if not version:
        raise ValueError("Version cannot be empty.")

    # ---------- 3-4: write into latest.json ----------

    section("Step 3-4: updating latest.json")
    latest["release_notes"] = release_notes
    latest["latest_version"] = version
    ok(f"latest_version -> {version}")

    # ---------- also write into release_manifest.json (asked for in step 1-2) ----------

    release_manifest["release_notes"] = release_notes
    release_manifest["version"] = version

    # ---------- 5: min_supported_version ----------

    section("Step 5: min_supported_version")
    gray(f"Current min_supported_version: {latest.get('min_supported_version', '')}")
    if confirm("Update min_supported_version?"):
        new_min = input("Enter new min_supported_version: ").strip()
        latest["min_supported_version"] = new_min
        ok(f"min_supported_version -> {new_min}")
    else:
        print("Keeping min_supported_version as-is.")

    # ---------- 6: download_endpoint ----------

    latest["download_endpoint"] = f"{version}/package.zip"
    ok(f"download_endpoint -> {latest['download_endpoint']}")

    # ---------- 7: backend ----------

    section("Step 7: backend")
    if confirm("Update backend?"):
        backend_dist = REPO_ROOT / "Melcosoft.Backend" / "dist" / "MelcosoftBackend"
        backend_internal = backend_dist / "_internal"
        backend_exe = backend_dist / "MelcosoftBackend.exe"
        backend_version_file = backend_dist / "_internal.version"
        dest_backend = LATEST_FILES / "backend"

        assert_path_exists(backend_internal, "Backend _internal folder")
        assert_path_exists(backend_exe, "MelcosoftBackend.exe")
        assert_path_exists(backend_version_file, "_internal.version")

        dest_backend.mkdir(parents=True, exist_ok=True)

        print("Zipping _internal...")
        zip_dir_contents(backend_internal, dest_backend / "_internal.zip")

        shutil.copy2(backend_version_file, dest_backend / "_internal.version")
        shutil.copy2(backend_exe, dest_backend / "MelcosoftBackend.exe")

        ok("Backend updated.")
    else:
        print("Skipping backend.")

    # ---------- 8: updater ----------

    section("Step 8: updater")
    if confirm("Update updater?"):
        updater_exe = (REPO_ROOT / "Melcosoft.Updater" / "Melcosoft.Updater" / "bin" / "Release"
                       / "net8.0-windows" / "win-x64" / "publish" / "Melcosoft.Updater.exe")
        dest_updater = LATEST_FILES / "updater"

        assert_path_exists(updater_exe, "Melcosoft.Updater.exe (publish output)")
        dest_updater.mkdir(parents=True, exist_ok=True)
        shutil.copy2(updater_exe, dest_updater / "Melcosoft.Updater.exe")

        ok("Updater updated.")
    else:
        print("Skipping updater.")

    # ---------- 9: service ----------

    section("Step 9: service")
    if confirm("Update service?"):
        service_exe = (REPO_ROOT / "Melcosoft.Service" / "bin" / "Release"
                        / "net8.0-windows" / "win-x64" / "publish" / "MelcosoftService.exe")
        dest_service = LATEST_FILES / "service"

        assert_path_exists(service_exe, "MelcosoftService.exe (publish output)")
        dest_service.mkdir(parents=True, exist_ok=True)
        shutil.copy2(service_exe, dest_service / "MelcosoftService.exe")

        ok("Service updated.")
    else:
        print("Skipping service.")

    # ---------- 10: extension ----------

    section("Step 10: extension")
    if confirm("Update extension?"):
        ext_root = REPO_ROOT / "Melcosoft.Extension"
        ext_dll = ext_root / "bin" / "x86" / "Release" / "net48" / "Melcosoft.dll"
        ext_yaml = ext_root / "extension.yaml"
        ext_resources = ext_root / "Resources"
        ext_localization = ext_root / "Localization"
        dest_ext = LATEST_FILES / "roaming_playnite" / "Extensions" / "Melcosoft"

        assert_path_exists(ext_dll, "Melcosoft.dll (build output)")
        assert_path_exists(ext_yaml, "extension.yaml")
        assert_path_exists(ext_resources, "Extension Resources folder")
        assert_path_exists(ext_localization, "Extension Localization folder")

        dest_ext.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ext_dll, dest_ext / "Melcosoft.dll")
        shutil.copy2(ext_yaml, dest_ext / "extension.yaml")
        copy_dir_mirror(ext_resources, dest_ext / "Resources")
        copy_dir_mirror(ext_localization, dest_ext / "Localization")

        ok("Extension updated.")
    else:
        print("Skipping extension.")

    # ---------- 11: launcher ----------

    section("Step 11: launcher")
    if confirm("Update launcher?"):
        playnite_dll = REPO_ROOT / "Melcosoft.Launcher" / "source" / "Playnite" / "bin" / "x86" / "Release" / "Playnite.dll"
        desktop_exe = (REPO_ROOT / "Melcosoft.Launcher" / "source" / "Playnite.DesktopApp"
                        / "bin" / "x86" / "Release" / "Playnite.DesktopApp.exe")
        fullscreen_exe = (REPO_ROOT / "Melcosoft.Launcher" / "source" / "Playnite.FullscreenApp"
                           / "bin" / "x86" / "Release" / "Playnite.FullscreenApp.exe")
        launcher_localization = REPO_ROOT / "Melcosoft.Launcher" / "source" / "Playnite" / "bin" / "x86" / "Release" / "Localization"
        dest_launcher = LATEST_FILES / "launcher"

        assert_path_exists(playnite_dll, "Playnite.dll")
        assert_path_exists(desktop_exe, "Playnite.DesktopApp.exe")
        assert_path_exists(fullscreen_exe, "Playnite.FullscreenApp.exe")
        assert_path_exists(launcher_localization, "Playnite Localization folder")

        dest_launcher.mkdir(parents=True, exist_ok=True)
        shutil.copy2(playnite_dll, dest_launcher / "Playnite.dll")
        shutil.copy2(desktop_exe, dest_launcher / "Playnite.DesktopApp.exe")
        shutil.copy2(fullscreen_exe, dest_launcher / "Playnite.FullscreenApp.exe")
        copy_dir_mirror(launcher_localization, dest_launcher / "Localization")

        ok("Launcher files updated.")
        warn("Themes were NOT touched by this script - update latest_files\\launcher\\Themes manually if needed.")
    else:
        print("Skipping launcher.")

    # ---------- 12: config ----------

    section("Step 12: config")
    if confirm("Should config be changed for this release?"):
        warn("Update latest_files\\config\\config.json manually - this script does not touch it.")
        input("Press Enter once you're done (or have decided not to change it): ")

    # ---------- 13: file_manifest.json ----------

    section("Step 13: file_manifest.json")
    if confirm("Should file_manifest.json be changed for this release?"):
        warn(f"Update {FILE_MANIFEST_PATH} manually now.")
        while not confirm("Type y once file_manifest.json is updated and ready"):
            print("Waiting...")

    # ---------- save release_manifest.json and latest.json so far ----------

    save_json(RELEASE_MANIFEST_PATH, release_manifest)
    save_json(LATEST_JSON_PATH, latest)
    ok("release_manifest.json and latest.json saved.")

    # ---------- 14: zip latest_files ----------

    section("Step 14: packaging")
    temp_zip = RELEASES_REPO / "package.zip"

    print("Zipping latest_files -> package.zip ...")
    zip_dir_contents(LATEST_FILES, temp_zip)
    ok("package.zip created.")

    # ---------- 15: move into version folder ----------

    section("Step 15: placing package")
    version_dir = RELEASES_REPO / version
    final_zip_path = version_dir / "package.zip"

    committed = git(RELEASES_REPO, "log", "--pretty=format:", "--name-only", "--", f"{version}/")
    if committed.stdout.strip():
        warn(f"Version folder '{version}' already exists in git history. Version folders are supposed to be immutable.")
        if not confirm("Overwrite anyway?"):
            print("Aborted.")
            sys.exit(1)

    version_dir.mkdir(parents=True, exist_ok=True)
    if final_zip_path.exists():
        final_zip_path.unlink()
    shutil.move(str(temp_zip), str(final_zip_path))
    print(f"package.zip -> {final_zip_path}")

    # ---------- 16-17: hash ----------

    section("Step 16-17: SHA256")
    result = subprocess.run(
        ["certutil", "-hashfile", str(final_zip_path), "SHA256"],
        capture_output=True, text=True, encoding="utf-8"
    )
    if result.returncode != 0:
        raise RuntimeError(f"certutil failed:\n{result.stdout}\n{result.stderr}")

    lines = result.stdout.splitlines()
    hash_line = re.sub(r"\s", "", lines[1]).lower() if len(lines) > 1 else ""
    if not re.fullmatch(r"[0-9a-f]{64}", hash_line):
        raise RuntimeError(f"Could not parse SHA256 from certutil output:\n{result.stdout}")

    print(f"SHA256: {hash_line}")

    latest["sha256"] = hash_line
    save_json(LATEST_JSON_PATH, latest)
    ok("latest.json sha256 updated.")

    # ---------- 18: final confirmation ----------

    section("Step 18: review before publishing")
    print(f"Version:            {version}")
    print(f"min_supported:      {latest.get('min_supported_version', '')}")
    print(f"download_endpoint:  {latest['download_endpoint']}")
    print(f"sha256:             {latest['sha256']}")
    print(f"mandatory:          {latest.get('mandatory', False)}")
    print("release_notes:")
    print(latest["release_notes"])
    print()

    if not confirm("Everything looks good - commit and push?"):
        print("Stopping before commit/push. Working tree changes are left in place for review.")
        return

    # ---------- 19-23: commit and push (Releases, then Launcher, then root -
    # in that order so the root repo's submodule pointers land on commits that
    # already exist on their remotes) ----------

    release_message = f"Release {version}"

    git_commit_push(RELEASES_REPO, "Step 19-21: Melcosoft.Releases", release_message)

    launcher_repo = REPO_ROOT / "Melcosoft.Launcher"
    git_commit_push(launcher_repo, "Step 22: Melcosoft.Launcher", release_message)

    git_commit_push(REPO_ROOT, "Step 23: root repo", release_message)

    ok(f"Release {version} published.")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"{Color.YELLOW}ERROR: {e}{Color.RESET}", file=sys.stderr)
        sys.exit(1)
