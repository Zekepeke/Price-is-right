import os
import httpx


async def get_prices(query: str) -> dict:
    async with httpx.AsyncClient() as client:
        token_res = await client.post(
            "https://api.ebay.com/identity/v1/oauth2/token",
            data="grant_type=client_credentials&scope=https://api.ebay.com/oauth/api_scope",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            auth=(os.environ["EBAY_CLIENT_ID"], os.environ["EBAY_CLIENT_SECRET"]),
        )
        token_res.raise_for_status()
        token = token_res.json()["access_token"]

        res = await client.get(
            "https://api.ebay.com/buy/browse/v1/item_summary/search",
            params={"q": query, "limit": 20, "filter": "buyingOptions:{FIXED_PRICE}"},
            headers={"Authorization": f"Bearer {token}"},
        )
        res.raise_for_status()
        items = res.json().get("itemSummaries", [])
        prices = sorted(
            float(i["price"]["value"])
            for i in items
            if "price" in i and "value" in i["price"]
        )

        if not prices:
            return {"low": 0.0, "high": 0.0, "median": 0.0, "count": 0}

        mid = len(prices) // 2
        median = (prices[mid - 1] + prices[mid]) / 2 if len(prices) % 2 == 0 else prices[mid]

        return {
            "low": round(prices[0], 2),
            "high": round(prices[-1], 2),
            "median": round(median, 2),
            "count": len(prices),
        }