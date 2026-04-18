import anthropic, os, json
from .prompt import PROMPT

def identify_item(image_base64: str) -> dict:
    client = anthropic.Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))
    msg = client.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=500,
        messages=[{
            "role": "user",
            "content": [
                {"type": "image", "source": {
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": image_base64
                }},
                {"type": "text", "text": PROMPT}
            ]
        }]
    )
    return json.loads(msg.content[0].text)
