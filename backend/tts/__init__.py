"""
TTS module. Call speak() with text, get back (audio_bytes, content_type).

Usage:
    from tts import speak
    audio_bytes, content_type = await speak("Your verdict text here")
"""
from .elevenlabs import synthesize


async def speak(text: str) -> tuple[bytes, str]:
    """Synthesize text to speech using ElevenLabs.

    Returns (audio_bytes, content_type).
    content_type is "audio/mpeg" (MP3).
    """
    audio = await synthesize(text)
    return audio, "audio/mpeg"
