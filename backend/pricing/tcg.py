import os
import httpx

BASE_URL = "https://api.justtcg.com/v1"


async def get_prices(query: str) -> dict:
    api_key = os.getenv("JUSTTCG_API_KEY")
    headers = {"X-API-Key": api_key}

    try:
        async with httpx.AsyncClient() as client:
            res = await client.get(
                f"{BASE_URL}/cards",
                params={"q": query},
                headers=headers,
            )
            res.raise_for_status()
            cards = res.json().get("data", [])

            if not cards:
                return {"low": 0, "high": 0, "median": 0, "count": 0}

            prices = []
            for card in cards:
                for variant in card.get("variants", []):
                    try:
                        price = variant.get("price")
                        if price is not None:
                            prices.append(float(price))
                    except (TypeError, ValueError):
                        continue

            if not prices:
                return {"low": 0, "high": 0, "median": 0, "count": 0}

            prices.sort()
            mid = len(prices) // 2
            median = (prices[mid - 1] + prices[mid]) / 2 if len(prices) % 2 == 0 else prices[mid]

            return {
                "low": prices[0],
                "high": prices[-1],
                "median": round(median, 2),
                "count": len(prices),
            }
    except Exception:
        return {"low": 0, "high": 0, "median": 0, "count": 0}


if __name__ == "__main__":
    import asyncio

    result = asyncio.run(get_prices("Charizard Base Set"))
    print(result)
