import os
import asyncio
import httpx

BASE_URL = "https://www.pricecharting.com"


async def get_prices(query: str) -> dict:
    token = os.getenv("PRICECHARTING_API_KEY")

    try:
        async with httpx.AsyncClient() as client:
            search_res = await client.get(
                f"{BASE_URL}/api/products",
                params={"t": token, "q": query},
            )
            search_res.raise_for_status()
            products = search_res.json().get("products", [])

            if not products:
                return {"low": 0, "high": 0, "median": 0, "count": 0}

            product_id = products[0]["id"]

            await asyncio.sleep(1)

            price_res = await client.get(
                f"{BASE_URL}/api/product",
                params={"t": token, "id": product_id},
            )
            price_res.raise_for_status()
            data = price_res.json()

            loose = data.get("loose-price")
            complete = data.get("complete-price")
            new = data.get("new-price")

            if loose is None and complete is None and new is None:
                return {"low": 0, "high": 0, "median": 0, "count": 0}

            # Prices are in pennies; convert to dollars
            low = round((loose or 0) / 100, 2)
            median = round((complete or 0) / 100, 2)
            high = round((new or 0) / 100, 2)

            return {"low": low, "high": high, "median": median, "count": 1}
    except Exception:
        return {"low": 0, "high": 0, "median": 0, "count": 0}


if __name__ == "__main__":
    result = asyncio.run(get_prices("Super Mario Bros 3 NES"))
    print(result)
