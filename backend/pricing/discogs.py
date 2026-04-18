import httpx, os

async def get_prices(query: str) -> dict:
    token = os.getenv("DISCOGS_TOKEN")
    headers = {
        "Authorization": f"Discogs token={token}",
        "User-Agent": "PriceIsRight/1.0",
    }

    async with httpx.AsyncClient() as client:
        search = await client.get(
            "https://api.discogs.com/database/search",
            params={"q": query, "type": "release", "per_page": 5},
            headers=headers,
        )
        results = search.json().get("results", [])
        if not results:
            return {"low": 0, "high": 0, "median": 0, "count": 0}
            
        release_id = results[0]["id"]
        stats_res = await client.get(
            f"https://api.discogs.com/marketplace/stats/{release_id}",
            headers=headers,
        )
        stats = stats_res.json()
        
        low = float((stats.get("lowest_price") or {}).get("value") or 0)
        count = stats.get("num_for_sale") or 0
        
        #Discogs stats endpoint only returns lowest price
        #for now this is fine but should be improved later by paginating /marketplace/search?release_id=...
        return {
            "low": low, 
            "high": low, 
            "median": low, 
            "count": count,
        }