import os
from fastapi import FastAPI
from pydantic import BaseModel
from dotenv import load_dotenv
from vision import claude, gemini
from pricing.ebay import get_prices

load_dotenv()
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
