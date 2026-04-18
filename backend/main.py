import os
import uuid
import base64
from typing import Optional
from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from pydantic import BaseModel
from dotenv import load_dotenv
from supabase import create_client, Client
from vision import claude, gemini
from pricing.ebay import get_prices

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


def identify_item(image_base64: str) -> dict:
    provider = os.getenv("VISION_PROVIDER", "claude").lower()
    if provider == "gemini":
        return gemini.identify_item(image_base64)
    return claude.identify_item(image_base64)


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

    item = identify_item(req.image_base64)
    pricing = await get_prices(item["ebay_search"])

    if pricing["count"] == 0:
        verdict = "No pricing data"
    else:
        median = pricing["median"]
        verdict = "Great deal" if median < 20 else "Fair price" if median < 60 else "Overpriced"

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
    }
