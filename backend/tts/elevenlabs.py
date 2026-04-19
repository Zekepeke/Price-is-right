import os
import httpx

VOICE_ID = "21m00Tcm4TlvDq8ikWAM"
MODEL_ID = "eleven_turbo_v2_5"


async def synthesize(text: str) -> bytes:
    url = f"https://api.elevenlabs.io/v1/text-to-speech/{VOICE_ID}"
    api_key = os.getenv("ELEVENLABS_API_KEY", "")
    headers = {
        "Accept": "audio/mpeg",
        "Content-Type": "application/json",
        "xi-api-key": api_key,
    }
    payload = {
        "text": text,
        "model_id": MODEL_ID,
        "voice_settings": {
            "stability": 0.5,
            "similarity_boost": 0.75,
            "style": 0.0,
            "use_speaker_boost": True,
        },
    }

    async with httpx.AsyncClient(timeout=30.0) as client:
        res = await client.post(url, headers=headers, json=payload)
        if res.status_code >= 400:
            raise RuntimeError(f"ElevenLabs error {res.status_code}: {res.text}")
        return res.content


if __name__ == "__main__":
    import asyncio

    async def _main() -> None:
        audio = await synthesize("Test from ElevenLabs text to speech.")
        with open("test_output.mp3", "wb") as f:
            f.write(audio)
        print(f"Saved test_output.mp3 ({len(audio)} bytes)")

    asyncio.run(_main())
