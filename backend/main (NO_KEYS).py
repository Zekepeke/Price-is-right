from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from google import genai
from google.genai import types
import PIL.Image, io, json, requests, tempfile, os
from pyzbar.pyzbar import decode
from pathlib import Path
from datetime import datetime

app = FastAPI()

# --- API Keys ---
client = genai.Client(api_key="GEMINAIKEY")
EBAY_KEY = "EBAYKEY"

# --- Gemini Prompt ---
PROMPT = (
    "Identify this item from a thrift store or resale photo. "
    "Return ONLY valid JSON with no markdown or code fences: "
    "{\"name\": \"...\", \"brand\": \"...\", \"model\": \"...\", "
    "\"category\": \"...\", \"condition\": \"good|fair|poor\"}. "
    "Be as specific as possible — include brand, model number, size, color if visible. "
    "If the item cannot be identified, return {\"name\": null}."
)


def try_barcode(img_bytes: bytes) -> dict | None:
    """Try to identify item via barcode/UPC first — faster and more reliable."""
    img = PIL.Image.open(io.BytesIO(img_bytes))
    barcodes = decode(img)
    if not barcodes:
        return None
    upc = barcodes[0].data.decode()
    r = requests.get(f"https://api.upcitemdb.com/prod/trial/lookup?upc={upc}", timeout=5)
    if r.ok:
        items = r.json().get("items", [])
        if items:
            i = items[0]
            return {"name": i.get("title"), "brand": i.get("brand"), "model": upc, "condition": "unknown"}
    return None


def identify_with_gemini(img_bytes: bytes) -> dict:
    """Fall back to Gemini vision if no barcode found."""
    image = PIL.Image.open(io.BytesIO(img_bytes))
    response = client.models.generate_content(
        model="gemini-2.5-flash",
        contents=[PROMPT, image]
    )
    text = (
        response.text.strip()
        .removeprefix("```json")
        .removeprefix("```")
        .removesuffix("```")
        .strip()
    )
    return json.loads(text)


def get_price(item: dict) -> dict | None:
    """Look up recent sold prices on eBay completed listings."""
    query = " ".join(filter(None, [
        item.get("brand"), item.get("name"), item.get("model")
    ])).strip()
    if not query:
        return None

    # Use sandbox endpoint for SBX keys, production for live keys
    is_sandbox = "SBX" in EBAY_KEY or "sbx" in EBAY_KEY
    base_url = (
        "https://svcs.sandbox.ebay.com/services/search/FindingService/v1"
        if is_sandbox else
        "https://svcs.ebay.com/services/search/FindingService/v1"
    )

    params = {
        "keywords": query,
        "OPERATION-NAME": "findCompletedItems",
        "SECURITY-APPNAME": EBAY_KEY,
        "RESPONSE-DATA-FORMAT": "JSON",
        "itemFilter(0).name": "SoldItemsOnly",
        "itemFilter(0).value": "true",
        "sortOrder": "EndTimeSoonest",
        "paginationInput.entriesPerPage": "20",
    }

    try:
        r = requests.get(base_url, params=params, timeout=5)
        data = r.json()
        items = data["findCompletedItemsResponse"][0]["searchResult"][0].get("item", [])
        if not items:
            return None
        prices = [float(i["sellingStatus"][0]["currentPrice"][0]["__value__"]) for i in items]
        return {
            "avg": round(sum(prices) / len(prices), 2),
            "low": round(min(prices), 2),
            "high": round(max(prices), 2),
            "sample_size": len(prices),
        }
    except Exception:
        return None


def build_speech(item: dict, price: dict | None) -> str:
    name = " ".join(filter(None, [
        item.get("brand"), item.get("name"), item.get("model")
    ])).strip()
    condition = item.get("condition", "unknown")

    if not price:
        return f"{name}. No recent eBay sales found."

    return (
        f"{name}. "
        f"Condition appears {condition}. "
        f"Recent eBay sales: average ${price['avg']}, "
        f"ranging from ${price['low']} to ${price['high']}."
    )


def log_to_collection(item: dict, price: dict | None, source: str):
    col = Path("collection.json")
    data = json.loads(col.read_text()) if col.exists() else []
    data.append({
        **item,
        "price": price,
        "scanned_at": datetime.now().isoformat(),
        "source": source,
    })
    col.write_text(json.dumps(data, indent=2))


@app.post("/identify")
async def identify(request: Request):
    img_bytes = await request.body()

    # 1. Try barcode
    item = try_barcode(img_bytes)
    source = "barcode"

    # 2. Fall back to Gemini
    if not item:
        try:
            item = identify_with_gemini(img_bytes)
            source = "vision"
        except Exception as e:
            return JSONResponse({"speech": f"Vision error: {str(e)}"}, status_code=500)

    if not item.get("name"):
        return {"speech": "Could not identify this item."}

    # 3. Price lookup
    price = get_price(item)

    # 4. Log to collection
    log_to_collection(item, price, source)

    # 5. Return speech string
    return {"speech": build_speech(item, price)}


@app.get("/collection")
async def get_collection():
    """Return full scanned collection with total estimated value."""
    col = Path("collection.json")
    if not col.exists():
        return {"items": [], "total_value": 0}
    data = json.loads(col.read_text())
    total = sum(
        item["price"]["avg"]
        for item in data
        if item.get("price") and item["price"].get("avg")
    )
    return {"items": data, "total_value": round(total, 2)}
