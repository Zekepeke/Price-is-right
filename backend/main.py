import os
from pathlib import Path

from dotenv import load_dotenv
from fastapi import FastAPI
from pydantic import BaseModel

from pricing.ebay import get_prices
from vision import claude, gemini

# Repo-root .env (one level above backend/). Use override=True so uvicorn --reload
# workers don't keep a stale GOOGLE_API_KEY from the parent process env.
load_dotenv(Path(__file__).resolve().parent.parent / ".env", override=True)
app = FastAPI()


class ScanRequest(BaseModel):
    image_base64: str


def identify_item(image_base64: str) -> dict:
    provider = os.getenv("VISION_PROVIDER", "claude").lower()
    if provider == "gemini":
        return gemini.identify_item(image_base64)
    return claude.identify_item(image_base64)


@app.post("/scan")
async def scan_item(req: ScanRequest):
    item = identify_item(req.image_base64)
    pricing = await get_prices(item["ebay_search"])

    median = pricing["median"]
    verdict = "Great deal" if median < 20 else "Fair price" if median < 60 else "Overpriced"

    return {"item": item, "pricing": pricing, "verdict": verdict}
