import httpx, os

async def get_prices(query: str) -> dict:
    q = query.lower()
    if any(w in q for w in ["pokemon", "pokémon", "charizard", "pikachu", "eevee"]):
        return await _pokemon(query)
    return await _scryfall(query)

async def _scryfall(query: str) -> dict:
    async with httpx.AsyncClient() as client:
        r = await client.get(
            "https://api.scryfall.com/cards/named",
            params={"fuzzy": query},
        )
        if r.status_code != 200:
            return {"low": 0, "high": 0, "median": 0, "count": 0}

        prices = r.json().get("prices", {}) or {}
        usd = float(prices.get("usd") or 0)
        usd_foil = float(prices.get("usd_foil") or 0)

        values = [v for v in (usd, usd_foil) if v > 0]
        if not values:
            return {"low": 0, "high": 0, "median": 0, "count": 0}

        return {
            "low": min(values),
            "high": max(values),
            "median": sorted(values)[len(values) // 2],
            "count": len(values),
        }

async def _pokemon(query: str) -> dict:
    headers = {}
    key = os.getenv("POKEMON_TCG_API_KEY")
    if key:
        headers["X-Api-Key"] = key
        
    async with httpx.AsyncClient() as client:
        r = await client.get(
            "https://api.pokemontcg.io/v2/cards",
            params={"q": f'name:"{query}"', "pageSize": 1},
            headers=headers,
        )
        cards = r.json().get("data", [])
        if not cards:
            return {"low": 0, "high": 0, "median": 0, "count": 0}
        
        tcg_prices = (
            cards[0]
            .get("tcgplayer", {})
            .get("prices", {})
            .get("normal", {})
        )
        if not tcg_prices:
            return {"low": 0, "high": 0, "median": 0, "count": 0}
        
        return {
            "low": float(tcg_prices.get("low") or 0),
            "high": float(tcg_prices.get("high") or 0),
            "median": float(tcg_prices.get("mid") or 0),
            "count": 1,
        }
        