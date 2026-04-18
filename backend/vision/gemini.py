import base64
import json
import os

from google import genai
from google.genai import types

from .prompt import PROMPT


def _parse_json_response(raw_text: str) -> dict:
    text = (raw_text or "").strip()
    if not text:
        raise RuntimeError("Gemini returned empty text")

    # Be resilient if provider wraps JSON in markdown fences.
    if text.startswith("```"):
        text = text.strip("`")
        if text.lower().startswith("json"):
            text = text[4:].strip()

    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        preview = text[:300]
        raise RuntimeError(f"Gemini returned non-JSON output: {preview}") from exc

def identify_item(image_base64: str) -> dict:
    client = genai.Client(api_key=os.getenv("GOOGLE_API_KEY"))
    image_bytes = base64.b64decode(image_base64)
    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=[
            types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
            PROMPT
        ],
        config=types.GenerateContentConfig(
            response_mime_type="application/json"
        )
    )
    return _parse_json_response(response.text)
