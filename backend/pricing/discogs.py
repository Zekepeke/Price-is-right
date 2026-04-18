import asyncio
import httpx, os


async def get_prices(query: str) -> dict:
    token = os.getenv("DISCOGS_TOKEN")
    headers = {
        "Authorization": f"Discogs token={token}",
        "User-Agent": "PriceIsRight/1.0",
    }
    zero = {"low": 0, "high": 0, "median": 0, "count": 0}

    async with httpx.AsyncClient(timeout=10.0) as client:
        try:
            search = await client.get(
                "https://api.discogs.com/database/search",
                params={"q": query, "type": "release", "per_page": 5},
                headers=headers,
            )
            results = search.json().get("results", [])
            if not results:
                return zero

            release_id = results[0]["id"]
            stats_res, sugg_res = await asyncio.gather(
                client.get(
                    f"https://api.discogs.com/marketplace/stats/{release_id}",
                    headers=headers,
                ),
                client.get(
                    f"https://api.discogs.com/marketplace/price_suggestions/{release_id}",
                    headers=headers,
                ),
            )
            count = stats_res.json().get("num_for_sale") or 0
            sugg = sugg_res.json() or {}

            def first_grade(*keys):
                for k in keys:
                    v = (sugg.get(k) or {}).get("value")
                    if v:
                        return float(v)
                return 0.0

            high = first_grade("Mint (M)", "Near Mint (NM or M-)")
            median = first_grade("Very Good Plus (VG+)", "Very Good (VG)")
            low = first_grade("Good Plus (G+)", "Good (G)", "Fair (F)")

            if not any([low, median, high]):
                fallback = round(float((stats_res.json().get("lowest_price") or {}).get("value") or 0), 2)
                return {"low": fallback, "high": fallback, "median": fallback, "count": count}

            high = high or median or low
            median = median or low or high
            low = low or median or high

            return {"low": round(low, 2), "high": round(high, 2), "median": round(median, 2), "count": count}
        except httpx.RequestError:
            return zero
