import os
import json
import re
import base64
from typing import Optional
from google import genai
from google.genai import types
from .prompt import build_prompt


def extract_barcode(image_base64: str) -> Optional[str]:
    """Returns barcode/ISBN number as string if found in image, else None."""
    client = genai.Client(api_key=os.environ["GOOGLE_API_KEY"])
    image_bytes = base64.b64decode(image_base64)
    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=[
            types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
            "If there is a barcode or ISBN in this image, reply with ONLY the numeric digits (8-13 digits). If there is no barcode or ISBN, reply with NONE.",
        ],
    )
    raw = response.text.strip()
    digits = re.sub(r"\D", "", raw)
    if 8 <= len(digits) <= 13:
        return digits
    return None


def identify_item(image_base64: str, context: str | None = None) -> dict:
    client = genai.Client(api_key=os.environ["GOOGLE_API_KEY"])
    image_bytes = base64.b64decode(image_base64)
    
    response = client.models.generate_content(
        model="gemini-2.5-flash", # Using the stable model name
        contents=[
            types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
            build_prompt(context),
        ],
        # This config guarantees the model outputs clean JSON
        config=types.GenerateContentConfig(
            response_mime_type="application/json",
        )
    )
    
    # Because of the config above, we no longer need the complex string splitting!
    return json.loads(response.text)