#!/usr/bin/env python3
"""Phoenix intake + deterministic template matching (stage 1).

Usage:
  python phoenix.py --text "Build a web FAQ chatbot with text chat"
  python phoenix.py --file requirement.txt
  python phoenix.py --file requirement.txt --client-name "Acme"

Required environment variable:
  GEMINI_API_KEY

This script only parses, matches, and records a lead. It does not clone,
build, submit, message clients, or deliver work.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from uuid import uuid4

ROOT = Path(__file__).resolve().parent
LEADS_PATH = ROOT / "leads.json"
TEMPLATES_PATH = ROOT / "templates.json"
HISTORY_PATH = ROOT / "history.json"
BUILDS_DIR = ROOT / "builds"
GEMINI_MODEL = os.getenv("GEMINI_MODEL", "gemini-2.5-flash")
GEMINI_ENDPOINT = (
    "https://generativelanguage.googleapis.com/v1beta/models/"
    + GEMINI_MODEL
    + ":generateContent"
)


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def read_json(path: Path, default: dict[str, Any]) -> dict[str, Any]:
    if not path.exists():
        return default
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_json_atomic(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temp_path = path.with_suffix(path.suffix + ".tmp")
    with temp_path.open("w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    temp_path.replace(path)


def extract_json(text: str) -> dict[str, Any]:
    """Accept plain JSON or JSON wrapped in a Markdown code fence."""
    cleaned = text.strip()
    cleaned = re.sub(r"^```(?:json)?\s*", "", cleaned, flags=re.IGNORECASE)
    cleaned = re.sub(r"\s*```$", "", cleaned)
    start, end = cleaned.find("{"), cleaned.rfind("}")
    if start < 0 or end < start:
        raise ValueError("Gemini response did not contain a JSON object.")
    parsed = json.loads(cleaned[start:end + 1])
    if not isinstance(parsed, dict):
        raise ValueError("Gemini response must be a JSON object.")
    return parsed


def gemini_parse(requirement: str, client_name: str | None) -> dict[str, Any]:
    api_key = os.getenv("GEMINI_API_KEY")
    if not api_key:
        raise RuntimeError("GEMINI_API_KEY is not set.")

    schema = {
        "type": "OBJECT",
        "properties": {
            "type": {"type": "STRING", "enum": ["chatbot", "app"]},
            "features": {"type": "ARRAY", "items": {"type": "STRING"}},
            "platform": {"type": "ARRAY", "items": {"type": "STRING"}},
            "constraints": {"type": "ARRAY", "items": {"type": "STRING"}}
        },
        "required": ["type", "features", "platform", "constraints"]
    }
    prompt = (
        "Convert the client requirement into a concise implementation spec. "
        "Return only the requested JSON. Use type 'chatbot' for conversational "
        "assistants/bots and 'app' for other applications. Features should be "
        "short, concrete labels (for example: text chat, FAQ, login, dashboard). "
        "Platforms should be normalized labels such as web, android, ios, or "
        "desktop. Put non-functional requirements, limits, integrations, budget, "
        "and exclusions in constraints. Do not invent requirements. "
        f"\nClient name: {client_name or 'Not provided'}"
        f"\nClient requirement:\n{requirement}"
    )
    body = {
        "contents": [{"parts": [{"text": prompt}]}],
        "generationConfig": {
            "temperature": 0,
            "responseMimeType": "application/json",
            "responseSchema": schema
        }
    }
    request = urllib.request.Request(
        GEMINI_ENDPOINT + "?key=" + api_key,
        data=json.dumps(body).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            payload = json.loads(response.read().decode("utf-8"))
    except urllib.error.HTTPError as exc:
        details = exc.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Gemini API HTTP {exc.code}: {details}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(f"Could not reach Gemini API: {exc}") from exc

    try:
        response_text = payload["candidates"][0]["content"]["parts"][0]["text"]
    except (KeyError, IndexError, TypeError) as exc:
        raise RuntimeError(f"Unexpected Gemini response: {payload}") from exc

    spec = extract_json(response_text)
    return validate_spec(spec)


def clean_labels(value: Any, field: str) -> list[str]:
    if not isinstance(value, list):
        raise ValueError(f"Spec field '{field}' must be a list.")
    labels = []
    for item in value:
        if isinstance(item, str) and item.strip():
            labels.append(item.strip())
    # Preserve order while removing duplicates case-insensitively.
    result, seen = [], set()
    for label in labels:
        key = normalize(label)
        if key and key not in seen:
            result.append(label)
            seen.add(key)
    return result


def validate_spec(spec: dict[str, Any]) -> dict[str, Any]:
    kind = str(spec.get("type", "")).strip().lower()
    if kind not in {"chatbot", "app"}:
        raise ValueError("Spec type must be 'chatbot' or 'app'.")
    return {
        "type": kind,
        "features": clean_labels(spec.get("features", []), "features"),
        "platform": clean_labels(spec.get("platform", []), "platform"),
        "constraints": clean_labels(spec.get("constraints", []), "constraints")
    }


def normalize(value: str) -> str:
    return re.sub(r"\s+", " ", re.sub(r"[^a-z0-9]+", " ", value.lower())).strip()


def match_template(spec: dict[str, Any], catalog: dict[str, Any]) -> dict[str, Any]:
    """Predictable exact-label matcher; no fuzzy or LLM-based fit decision."""
    requested_features = {normalize(x) for x in spec["features"]}
    requested_platforms = {normalize(x) for x in spec["platform"]}
    candidates = []

    for template in catalog.get("templates", []):
        if normalize(template.get("type", "")) != normalize(spec["type"]):
            continue

        required = {normalize(x) for x in template.get("required_features", [])}
        any_features = {normalize(x) for x in template.get("any_features", [])}
        template_features = {normalize(x) for x in template.get("features", [])}
        supported_platforms = {
            normalize(x) for x in template.get("platforms", [])
        }

        if not required.issubset(requested_features):
            continue
        if any_features and not (any_features & requested_features):
            continue
        if requested_platforms and supported_platforms:
            if not (requested_platforms & supported_platforms):
                continue

        matched_features = requested_features & template_features
        matched_keywords = {
            normalize(x) for x in template.get("keywords", [])
        } & requested_features
        platform_hits = requested_platforms & supported_platforms
        score = (len(matched_features) * 3) + len(matched_keywords) + len(platform_hits)
        candidates.append((score, template.get("id", ""), template))

    if not candidates:
        return {
            "status": "needs_custom_build",
            "template_id": None,
            "template_name": "custom",
            "reason": "No template satisfied the deterministic match rules."
        }

    # Stable tie-break: highest score, then lexicographically smallest template id.
    candidates.sort(key=lambda item: (-item[0], item[1]))
    selected = candidates[0][2]
    return {
        "status": "template_matched",
        "template_id": selected["id"],
        "template_name": selected.get("name", selected["id"]),
        "score": candidates[0][0],
        "reason": "Required features and platform rules matched."
    }


def main() -> int:
    parser = argparse.ArgumentParser(description="Phoenix freelance intake + matcher")
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--text", help="Client requirement as plain text")
    source.add_argument("--file", help="UTF-8 text file containing the requirement")
    parser.add_argument("--client-name", default="", help="Optional client label")
    parser.add_argument("--lead-id", default="", help="Optional stable lead ID")
    args = parser.parse_args()

    if args.file:
        requirement_path = Path(args.file)
        if not requirement_path.is_absolute():
            requirement_path = Path.cwd() / requirement_path
        requirement = requirement_path.read_text(encoding="utf-8").strip()
        source_label = str(requirement_path)
    else:
        requirement = args.text.strip()
        source_label = "command-line text"

    if not requirement:
        parser.error("Requirement text is empty.")

    try:
        spec = gemini_parse(requirement, args.client_name or None)
        catalog = read_json(TEMPLATES_PATH, {"version": 1, "templates": []})
        match = match_template(spec, catalog)

        lead_id = args.lead_id.strip() or (
            "lead-" + datetime.now(timezone.utc).strftime("%Y%m%d-%H%M%S")
            + "-" + uuid4().hex[:6]
        )
        created_at = now_iso()
        lead = {
            "id": lead_id,
            "created_at": created_at,
            "client_name": args.client_name.strip() or None,
            "source": source_label,
            "requirement": requirement,
            "spec": spec,
            "match": match,
            "build_status": "not_started",
            "human_review": {"pass_fail": None, "reviewed_by": None, "reviewed_at": None},
            "submission_status": "manual_only"
        }

        leads_data = read_json(LEADS_PATH, {"version": 1, "leads": []})
        if any(item.get("id") == lead_id for item in leads_data.get("leads", [])):
            raise ValueError(f"Lead ID already exists: {lead_id}")
        leads_data.setdefault("leads", []).append(lead)
        write_json_atomic(LEADS_PATH, leads_data)

        event = {
            "timestamp": created_at,
            "event": "intake_and_template_match",
            "lead_id": lead_id,
            "status": match["status"],
            "template_id": match["template_id"]
        }
        history_data = read_json(HISTORY_PATH, {"version": 1, "events": []})
        history_data.setdefault("events", []).append(event)
        write_json_atomic(HISTORY_PATH, history_data)

        lead_dir = BUILDS_DIR / lead_id
        lead_dir.mkdir(parents=True, exist_ok=False)
        write_json_atomic(lead_dir / "spec.json", spec)
        write_json_atomic(lead_dir / "match.json", match)
        (lead_dir / "requirement.txt").write_text(requirement + "\n", encoding="utf-8")

        print(json.dumps({
            "lead_id": lead_id,
            "spec": spec,
            "match": match,
            "review_path": str(lead_dir.relative_to(ROOT))
        }, indent=2, ensure_ascii=False))
        return 0

    except Exception as exc:
        print(f"PHOENIX ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
