import os
import json
import base64
from google import genai
from google.genai import types
from .prompt import PROMPT


def identify_item(image_base64: str) -> dict:
    client = genai.Client(api_key=os.environ["GOOGLE_API_KEY"])
    image_bytes = base64.b64decode(image_base64)
    response = client.models.generate_content(
        model="gemini-2.0-flash",
        contents=[
            types.Part.from_bytes(data=image_bytes, mime_type="image/jpeg"),
            PROMPT,
        ],
    )
    raw = response.text.strip()
    if raw.startswith("```"):
        raw = raw.split("```")[1]
        if raw.startswith("json"):
            raw = raw[4:]
    return json.loads(raw.strip())
