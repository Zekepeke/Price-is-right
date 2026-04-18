from fastapi import FastAPI
from pydantic import BaseModel
import anthropic, httpx, base64, os
from dotenv import load_dotenv

load_dotenv()
app = FastAPI()
claude = anthropic.Anthropic(api_key=os.getenv("ANTHROPIC_API_KEY"))

class ScanRequest(BaseModel):
    image_base64: str  # iOS app will send this


@app.post("/scan")
async def scan_item(req: ScanRequest):
    # Step 1: identify item with Claude vision
    msg = claude.messages.create(
        model="claude-sonnet-4-5",
        max_tokens=500,
        messages=[{
            "role": "user",
            "content": [
                {"type": "image", "source": {
                    "type": "base64",
                    "media_type": "image/jpeg",
                    "data": req.image_base64
                }},
                {"type": "text", "text": """Identify this second-hand item. 
                Return JSON only: 
                {"category": "", "brand": "", "condition": "", "ebay_search": ""}"""}
            ]
        }]
    )
    
    import json
    item = json.loads(msg.content[0].text)

    # Step 2: query eBay
    pricing = await get_ebay_prices(item["ebay_search"])

    # Step 3: verdict
    median = pricing["median"]
    verdict = "🔥 Great deal" if median < 20 else "👍 Fair price" if median < 60 else "⚠️ Overpriced"

    return {"item": item, "pricing": pricing, "verdict": verdict}


async def get_ebay_prices(query: str):
    # get token
    async with httpx.AsyncClient() as client:
        token_res = await client.post(
            "https://api.ebay.com/identity/v1/oauth2/token",
            data="grant_type=client_credentials&scope=https://api.ebay.com/oauth/api_scope",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            auth=(os.getenv("EBAY_CLIENT_ID"), os.getenv("EBAY_CLIENT_SECRET"))
        )
        token = token_res.json()["access_token"]

        # search listings
        res = await client.get(
            "https://api.ebay.com/buy/browse/v1/item_summary/search",
            params={"q": query, "limit": 10, "filter": "buyingOptions:{FIXED_PRICE}"},
            headers={"Authorization": f"Bearer {token}"}
        )
        items = res.json().get("itemSummaries", [])
        prices = sorted([float(i["price"]["value"]) for i in items])
        
        return {
            "low": prices[0] if prices else 0,
            "high": prices[-1] if prices else 0,
            "median": prices[len(prices)//2] if prices else 0,
            "count": len(prices)
        }