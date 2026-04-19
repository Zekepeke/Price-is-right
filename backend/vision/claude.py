import os
import json
import re
from typing import Optional
import anthropic
from .prompt import build_prompt


def extract_barcode(image_base64: str) -> Optional[str]:
    """Returns barcode/ISBN number as string if found in image, else None."""
    client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
    msg = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=64,
        messages=[{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": image_base64,
                    },
                },
                {"type": "text", "text": "If there is a barcode or ISBN in this image, reply with ONLY the numeric digits (8-13 digits). If there is no barcode or ISBN, reply with NONE."},
            ],
        }],
    )
    raw = msg.content[0].text.strip()
    digits = re.sub(r"\D", "", raw)
    if 8 <= len(digits) <= 13:
        return digits
    return None


def identify_item(image_base64: str, context: str | None = None) -> dict:
    client = anthropic.Anthropic(api_key=os.environ["ANTHROPIC_API_KEY"])
    msg = client.messages.create(
        model="claude-sonnet-4-6",
        max_tokens=512,
        messages=[{
            "role": "user",
            "content": [
                {
                    "type": "image",
                    "source": {
                        "type": "base64",
                        "media_type": "image/jpeg",
                        "data": image_base64,
                    },
                },
                {"type": "text", "text": build_prompt(context)},
            ],
        }],
    )
    raw = msg.content[0].text.strip()
    if raw.startswith("```"):
        raw = raw.split("```")[1]
        if raw.startswith("json"):
            raw = raw[4:]
    return json.loads(raw.strip())
