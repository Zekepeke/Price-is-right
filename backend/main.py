import os
import uuid
import base64
from typing import Optional
import httpx
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from dotenv import load_dotenv
from supabase import create_client, Client
from vision import claude, gemini
from pricing import ebay, discogs, tcg
from tts import elevenlabs

load_dotenv()
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
    context: Optional[str] = None


async def extract_barcode(image_base64: str) -> Optional[str]:
    """Ask the vision model if there's a barcode/ISBN in the image. Returns the number or None."""
    provider = os.getenv("VISION_PROVIDER", "claude").lower()
    if provider == "gemini":
        return gemini.extract_barcode(image_base64)
    return claude.extract_barcode(image_base64)


async def lookup_barcode(barcode: str) -> Optional[dict]:
    async with httpx.AsyncClient(timeout=5.0) as client:
        try:
            r = await client.get(f"https://world.openfoodfacts.org/api/v0/product/{barcode}.json")
            data = r.json()
            if data.get("status") == 1:
                p = data["product"]
                name = p.get("product_name", "")
                brand = p.get("brands", "").split(",")[0].strip()
                if name:
                    return {"category": "packaged food", "brand": brand, "condition": "new",
                            "pricing_source": "ebay", "search_query": f"{brand} {name}".strip(),
                            "confidence": 0.99}
        except Exception:
            pass

        try:
            r = await client.get(f"https://openlibrary.org/api/books?bibkeys=ISBN:{barcode}&format=json&jscmd=data")
            data = r.json()
            if data:
                book = list(data.values())[0]
                title = book.get("title", "")
                authors = book.get("authors", [{}])
                author = authors[0].get("name", "") if authors else ""
                if title:
                    return {"category": "book", "brand": author, "condition": "good",
                            "pricing_source": "ebay", "search_query": f"{title} {author}".strip(),
                            "confidence": 0.99}
        except Exception:
            pass

        try:
            r = await client.get(f"https://api.upcitemdb.com/prod/trial/lookup?upc={barcode}")
            data = r.json()
            items = data.get("items", [])
            if items:
                item = items[0]
                return {"category": item.get("category", ""), "brand": item.get("brand", ""),
                        "condition": "new", "pricing_source": "ebay",
                        "search_query": item.get("title", ""),
                        "confidence": 0.99}
        except Exception:
            pass

    return None


def identify_item(image_base64: str, context: Optional[str] = None) -> dict:
    provider = os.getenv("VISION_PROVIDER", "claude").lower()
    if provider == "gemini":
        return gemini.identify_item(image_base64, context=context)
    return claude.identify_item(image_base64, context=context)


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

    supabase.storage.from_("scan-images").upload(
        file_name,
        image_bytes,
        {"content-type": "image/jpeg"},
    )
    image_url = supabase.storage.from_("scan-images").get_public_url(file_name)

    item = None
    barcode = await extract_barcode(req.image_base64)
    if barcode:
        print(f"[BARCODE] detected: {barcode}")
        item = await lookup_barcode(barcode)
        if item:
            print(f"[BARCODE] resolved: {item}")

    if not item:
        item = identify_item(req.image_base64, context=req.context)
    print(f"[VISION] item={item}")

    source = item.get("pricing_source", "ebay")
    query = item.get("search_query") or item.get("ebay_search", "")
    brand = item.get("brand", "")
    print(f"[PRICING] source={source!r}  query={query!r}  brand={brand!r}")

    pricing = await get_prices_with_fallback(source, query, brand)
    print(f"[PRICING] result={pricing}")

    if pricing["count"] == 0:
        verdict = "No pricing data"
        net_profit = 0.0
    else:
        median = pricing["median"]
        verdict = "Great deal" if median < 20 else "Fair price" if median < 60 else "Overpriced"
        net_profit = median - (median * 0.1325) - 5

    spoken_text = f"{verdict}. Price range: ${pricing['low']:.2f} to ${pricing['high']:.2f}. After fees, you'd net about ${net_profit:.2f} per sale."
    audio_base64 = None
    try:
        audio_bytes = await elevenlabs.synthesize(spoken_text)
        audio_base64 = base64.b64encode(audio_bytes).decode("utf-8")
    except Exception as e:
        print(f"[TTS] ElevenLabs failed, skipping audio: {e}")

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
        "source": "ebay",
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
        "audio": {"data": audio_base64, "content_type": "audio/mpeg"} if audio_base64 else None,
        "net_profit": round(net_profit, 2),
    }
