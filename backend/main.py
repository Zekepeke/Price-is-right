import os
<<<<<<< HEAD
from pathlib import Path

from dotenv import load_dotenv
=======
import uuid
import base64
from typing import Optional
>>>>>>> main
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
<<<<<<< HEAD

=======
from dotenv import load_dotenv
from supabase import create_client, Client
from vision import claude, gemini
<<<<<<< HEAD
>>>>>>> main
from pricing.ebay import get_prices
from vision import claude, gemini
=======
from pricing import ebay, discogs, tcg
from summary import generate_summary
from tts import speak
from tts.script import build_speech
>>>>>>> 13125b48ce8922cfc5179a08752aadc7969ea04b

# Repo-root .env (one level above backend/). Use override=True so uvicorn --reload
# workers don't keep a stale GOOGLE_API_KEY from the parent process env.
load_dotenv(Path(__file__).resolve().parent.parent / ".env", override=True)
app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_methods=["*"],
    allow_headers=["*"],
)

supabase: Client = create_client(
    os.environ["SUPABASE_URL"],
    os.environ["SUPABASE_SERVICE_KEY"],
)


class ScanRequest(BaseModel):
    image_base64: str
    user_id: Optional[str] = None


def identify_item(image_base64: str) -> dict:
    provider = os.getenv("VISION_PROVIDER", "claude").lower()
    if provider == "gemini":
        return gemini.identify_item(image_base64)
    return claude.identify_item(image_base64)


async def get_prices_with_fallback(source: str, query: str, brand: str = "") -> dict:
    pricing = {"low": 0, "high": 0, "median": 0, "count": 0}
    actual_source = source
    used_fallback = False

    if source == "discogs":
        pricing = await discogs.get_prices(query)
        if pricing["count"] == 0:
            print(f"[PRICING] discogs returned 0, falling back to eBay")
            pricing = await ebay.get_prices(query)
            actual_source = "ebay"
            used_fallback = True
    elif source == "tcg":
        pricing = await tcg.get_prices(query, brand)
        if pricing["count"] == 0:
            print(f"[PRICING] tcg returned 0, falling back to eBay")
            pricing = await ebay.get_prices(query)
            actual_source = "ebay"
            used_fallback = True
    else:
        pricing = await ebay.get_prices(query)

    return {
        **pricing,
        "requested_source": source,
        "actual_source": actual_source,
        "used_fallback": used_fallback,
    }


@app.post("/scan")
async def scan_item(req: ScanRequest):
    provider = os.getenv("VISION_PROVIDER", "claude").lower()

    image_bytes = base64.b64decode(req.image_base64)
    file_name = f"{uuid.uuid4()}.jpg"

    image_url = None
    try:
        supabase.storage.from_("scan-images").upload(
            file_name,
            image_bytes,
            {"content-type": "image/jpeg"},
        )
        image_url = supabase.storage.from_("scan-images").get_public_url(file_name)
    except Exception as e:
        print(f"[STORAGE] upload failed (non-fatal): {type(e).__name__}: {e}")

    item = identify_item(req.image_base64)
    print(f"[VISION] item={item}")

    source = item.get("pricing_source", "ebay")
    query = item.get("search_query") or item.get("ebay_search", "")
    brand = item.get("brand", "")
    print(f"[PRICING] source={source!r}  query={query!r}  brand={brand!r}")

    pricing = await get_prices_with_fallback(source, query, brand)
    print(f"[PRICING] result={pricing}")

    if pricing["count"] == 0:
        verdict = "No pricing data"
    else:
        median = pricing["median"]
        verdict = "Great deal" if median < 20 else "Fair price" if median < 60 else "Overpriced"

    print(f"[SUMMARY] generating...")
    try:
        summary = generate_summary(item, pricing, verdict)
        if not summary:
            raise ValueError("Empty summary returned")
    except Exception as e:
        print(f"[SUMMARY] ERROR: {type(e).__name__}: {e}")
        summary = build_speech(item, pricing, verdict)
    print(f"[SUMMARY] {summary!r}")

    audio_b64 = None
    audio_content_type = None
    try:
        audio_bytes, audio_content_type = await speak(summary)
        audio_b64 = base64.b64encode(audio_bytes).decode()
    except Exception as e:
        print(f"[TTS] ERROR: {type(e).__name__}: {e}")

    scan_row = supabase.table("scans").insert({
        "user_id": req.user_id,
        "image_url": image_url,
        "category": item.get("category"),
        "brand": item.get("brand"),
        "condition": item.get("condition"),
        "verdict": verdict,
        "vision_provider": provider,
        "confidence": item.get("confidence"),
    }).execute()

    scan_id = scan_row.data[0]["id"]

    supabase.table("pricing_results").insert({
        "scan_id": scan_id,
        "source": pricing["actual_source"],
        "price_low": pricing["low"],
        "price_high": pricing["high"],
        "price_median": pricing["median"],
        "item_count": pricing["count"],
    }).execute()

    return {
        "scan_id": scan_id,
        "item": item,
        "pricing": pricing,
        "verdict": verdict,
        "image_url": image_url,
        "summary": summary,
        "audio": {
            "data": audio_b64,
            "content_type": audio_content_type,
        } if audio_b64 else None,
    }
