#!/usr/bin/env python3
"""Update altstore.json for LiveContainer & SideStore after building an iOS IPA."""

from __future__ import annotations

import argparse
import hashlib
import json
import plistlib
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def compute_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as fp:
        for chunk in iter(lambda: fp.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest().lower()


def load_info_plist(app_bundle: Path) -> dict[str, Any]:
    info_plist_path = app_bundle / "Info.plist"
    if not info_plist_path.is_file():
        raise FileNotFoundError(f"Info.plist not found at {info_plist_path}")
    with info_plist_path.open("rb") as fp:
        data = plistlib.load(fp)
    if not isinstance(data, dict):
        raise ValueError("Parsed Info.plist is not a dictionary")
    return data


def extract_privacy_permissions(info: dict[str, Any]) -> dict[str, str]:
    privacy: dict[str, str] = {}
    for key in sorted(info.keys()):
        if key.startswith("NS") and key.endswith("UsageDescription"):
            val = info.get(key)
            if isinstance(val, str):
                privacy[key] = val
    return privacy


def extract_entitlements(app_bundle: Path) -> list[str]:
    entitlements: set[str] = set()
    targets = [app_bundle]
    plug_ins = app_bundle / "PlugIns"
    if plug_ins.is_dir():
        targets.extend(sorted(plug_ins.glob("*.appex")))

    ignored_keys = {
        "application-identifier",
        "com.apple.developer.team-identifier",
        "get-task-allow",
        "keychain-access-groups",
    }

    for target in targets:
        try:
            proc = subprocess.run(
                ["codesign", "-d", "--entitlements", ":-", str(target)],
                capture_output=True,
                check=False,
            )
        except FileNotFoundError:
            # Non-macOS local test environment without `codesign`
            break

        stdout = proc.stdout.strip()
        if proc.returncode != 0 or not stdout:
            continue
        xml_start = stdout.find(b"<?xml")
        if xml_start == -1:
            continue
        try:
            parsed = plistlib.loads(stdout[xml_start:])
        except Exception:
            continue
        if isinstance(parsed, dict):
            for key in parsed.keys():
                if key not in ignored_keys:
                    entitlements.add(str(key))

    return sorted(entitlements)


def build_default_manifest(repo: str, bundle_id: str, app_name: str) -> dict[str, Any]:
    owner = repo.split("/")[0] if "/" in repo else "ZimingADR"
    owner_lower = owner.lower()
    raw_base = f"https://raw.githubusercontent.com/{repo}/main"
    icon_url = (
        f"{raw_base}/ios/Runner/Assets.xcassets/"
        "AppIcon.appiconset/Icon-App-1024x1024@1x.png"
    )
    return {
        "name": app_name,
        "subtitle": "融合 BewlyCat 智能音量平衡的第三方 BiliBili 客户端",
        "description": (
            "基于 PiliNara 融合 BewlyCat 智能音量平衡（跨视频响度对齐 + 视频内局部动态平滑 + 防爆音限制），"
            "支持 LiveContainer 与 SideStore 一键安装与更新。"
        ),
        "identifier": f"io.github.{owner_lower}.pilinara.source",
        "sourceURL": f"{raw_base}/altstore.json",
        "website": f"https://github.com/{repo}",
        "iconURL": icon_url,
        "tintColor": "#FB7299",
        "featuredApps": [bundle_id],
        "apps": [
            {
                "name": app_name,
                "bundleIdentifier": bundle_id,
                "developerName": owner,
                "subtitle": "支持智能音量平衡的第三方 BiliBili 客户端",
                "localizedDescription": (
                    "使用 Flutter 开发的第三方 BiliBili 客户端，融合 BewlyCat 智能音量平衡"
                    "（跨视频响度对齐 + 单视频局部动态平滑 + -1.0 dBFS 峰值防破音），"
                    "支持普通播放、后台播放、后台只听音频、听视频、独立听音频、画中画、离线缓存与直播。"
                ),
                "iconURL": icon_url,
                "tintColor": "#FB7299",
                "category": "entertainment",
                "screenshotURLs": [
                    f"{raw_base}/assets/screenshots/home.png",
                    f"{raw_base}/assets/screenshots/bangumi_detail.png",
                    f"{raw_base}/assets/screenshots/dynamic.png",
                ],
                "appPermissions": {
                    "entitlements": [],
                    "privacy": {},
                },
                "versions": [],
            }
        ],
        "news": [],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-json", required=True, type=Path)
    parser.add_argument("--app-bundle", required=True, type=Path)
    parser.add_argument("--ipa", required=True, type=Path)
    parser.add_argument("--download-url", required=True)
    parser.add_argument("--repo", default="ZimingADR/PiliNara")
    parser.add_argument("--version", default="")
    parser.add_argument("--build-version", default="")
    parser.add_argument("--description", default="")
    parser.add_argument("--date", default="")
    parser.add_argument("--max-versions", type=int, default=20)
    args = parser.parse_args()

    if not args.ipa.is_file():
        raise FileNotFoundError(f"IPA file not found at {args.ipa}")

    info = load_info_plist(args.app_bundle)
    bundle_id = str(info.get("CFBundleIdentifier") or "com.example.pilinara")
    app_name = str(
        info.get("CFBundleDisplayName")
        or info.get("CFBundleName")
        or "PiliNara"
    )
    short_version = str(
        args.version or info.get("CFBundleShortVersionString") or "2.1.0"
    )
    build_version = str(
        args.build_version or info.get("CFBundleVersion") or "1"
    )
    min_os_version = str(info.get("MinimumOSVersion") or "14.0")

    ipa_size = args.ipa.stat().st_size
    ipa_sha256 = compute_sha256(args.ipa)
    release_date = args.date or datetime.now(timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    version_desc = (
        args.description.strip()
        or f"PiliNara iOS {short_version} (Build {build_version})"
    )

    if args.source_json.is_file():
        manifest = json.loads(args.source_json.read_text(encoding="utf-8"))
    else:
        manifest = build_default_manifest(args.repo, bundle_id, app_name)

    owner = args.repo.split("/")[0] if "/" in args.repo else "ZimingADR"
    raw_base = f"https://raw.githubusercontent.com/{args.repo}/main"
    icon_url = (
        f"{raw_base}/ios/Runner/Assets.xcassets/"
        "AppIcon.appiconset/Icon-App-1024x1024@1x.png"
    )

    manifest["sourceURL"] = f"{raw_base}/altstore.json"
    manifest["website"] = f"https://github.com/{args.repo}"
    manifest["iconURL"] = icon_url
    manifest["featuredApps"] = [bundle_id]

    apps = manifest.setdefault("apps", [])
    if not apps:
        apps.append(
            build_default_manifest(args.repo, bundle_id, app_name)["apps"][0]
        )

    app_entry = apps[0]
    app_entry["name"] = app_name
    app_entry["bundleIdentifier"] = bundle_id
    app_entry["developerName"] = owner
    app_entry["iconURL"] = icon_url
    app_entry["appPermissions"] = {
        "entitlements": extract_entitlements(args.app_bundle),
        "privacy": extract_privacy_permissions(info),
    }

    new_version_item = {
        "version": short_version,
        "buildVersion": build_version,
        "buildNumber": build_version,
        "date": release_date,
        "localizedDescription": version_desc,
        "downloadURL": args.download_url,
        "size": ipa_size,
        "sha256": ipa_sha256,
        "minOSVersion": min_os_version,
    }

    existing_versions: list[dict[str, Any]] = [
        item
        for item in app_entry.get("versions", [])
        if isinstance(item, dict)
        and not (
            str(item.get("version")) == short_version
            and str(item.get("buildVersion", item.get("buildNumber", "")))
            == build_version
        )
    ]
    app_entry["versions"] = [new_version_item, *existing_versions][
        : max(1, args.max_versions)
    ]

    # Legacy AltStore v1 top-level app properties for broad sideload client compatibility
    app_entry["version"] = short_version
    app_entry["versionDate"] = release_date
    app_entry["versionDescription"] = version_desc
    app_entry["downloadURL"] = args.download_url
    app_entry["size"] = ipa_size

    args.source_json.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    print(
        f"Updated {args.source_json}: {app_name} ({bundle_id}) "
        f"v{short_version} ({build_version}), size={ipa_size}, sha256={ipa_sha256}"
    )


if __name__ == "__main__":
    main()
