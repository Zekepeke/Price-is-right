import httpx, os

async def get_prices(query: str) -> dict:
    async with httpx.AsyncClient() as client:
        token_res = await client.post(
            "https://api.ebay.com/identity/v1/oauth2/token",
            data="grant_type=client_credentials&scope=https://api.ebay.com/oauth/api_scope",
            headers={"Content-Type": "application/x-www-form-urlencoded"},
            auth=(os.getenv("EBAY_CLIENT_ID"), os.getenv("EBAY_CLIENT_SECRET"))
        )
        token_res.raise_for_status()
        token = token_res.json().get("access_token")
        if not token:
            raise RuntimeError("eBay token response missing access_token")

        res = await client.get(
            "https://api.ebay.com/buy/browse/v1/item_summary/search",
            params={"q": query, "limit": 10, "filter": "buyingOptions:{FIXED_PRICE}"},
            headers={"Authorization": f"Bearer {token}"}
        )
        res.raise_for_status()
        items = res.json().get("itemSummaries", [])
        prices = []
        for item in items:
            value = item.get("price", {}).get("value")
            if value is None:
                continue
            try:
                prices.append(float(value))
            except (TypeError, ValueError):
                continue
        prices.sort()

        return {
            "low": prices[0] if prices else 0,
            "high": prices[-1] if prices else 0,
            "median": prices[len(prices) // 2] if prices else 0,
            "count": len(prices)
        }
