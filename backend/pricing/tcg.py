import os
import httpx

BASE_URL = "https://api.justtcg.com/v1"

BRAND_TO_GAME = {
    "pokemon": "pokemon",
    "magic": "mtg",
    "magic: the gathering": "mtg",
    "mtg": "mtg",
    "yu-gi-oh": "yugioh",
    "yugioh": "yugioh",
    "disney lorcana": "lorcana",
    "lorcana": "lorcana",
    "one piece": "one-piece",
    "digimon": "digimon",
}


def _parse_query(query: str) -> tuple[str, str]:
    """Split 'Charizard Base Set 4/102' into (card_name, set_name).
    Heuristic: last token that looks like a set number ends the set portion.
    Falls back to first word as card name, rest as set name."""
    parts = query.strip().split()
    # Strip trailing card number like "4/102" or "SWSH001"
    while parts and ("/" in parts[-1] or parts[-1].replace("-", "").isalnum() and parts[-1][0].isdigit()):
        parts.pop()
    if not parts:
        return query, ""
    # First word(s) up to a known set-like word are the card name.
    # Simple split: first word = card name, rest = set name
    card_name = parts[0]
    set_name = " ".join(parts[1:]) if len(parts) > 1 else ""
    return card_name, set_name


async def get_prices(query: str, game: str = "") -> dict:
    api_key = os.getenv("JUSTTCG_API_KEY")
    headers = {"X-API-Key": api_key}
    game_id = BRAND_TO_GAME.get(game.lower(), "pokemon")
    card_name, set_name = _parse_query(query)
    print(f"[TCG] query={query!r}  game_id={game_id}  card={card_name!r}  set={set_name!r}")

    try:
        async with httpx.AsyncClient() as client:
            # Step 1: resolve set ID
            set_id = None
            if set_name:
                sets_res = await client.get(
                    f"{BASE_URL}/sets",
                    params={"game": game_id, "q": set_name},
                    headers=headers,
                )
                print(f"[TCG] sets status={sets_res.status_code}  body={sets_res.text[:300]}")
                sets_res.raise_for_status()
                sets_data = sets_res.json().get("data", [])
                if sets_data:
                    set_id = sets_data[0]["id"]
                    print(f"[TCG] resolved set_id={set_id!r}")

            # Step 2: search cards
            params = {"q": card_name}
            if set_id:
                params["set"] = set_id
            else:
                params["game"] = game_id

            cards_res = await client.get(
                f"{BASE_URL}/cards",
                params=params,
                headers=headers,
            )
            print(f"[TCG] cards status={cards_res.status_code}  body={cards_res.text[:400]}")
            cards_res.raise_for_status()
            cards = cards_res.json().get("data", [])
            print(f"[TCG] cards returned={len(cards)}")

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

            print(f"[TCG] prices extracted={len(prices)}  sample={prices[:5]}")
            if not prices:
                return {"low": 0, "high": 0, "median": 0, "count": 0}

            prices.sort()
            mid = len(prices) // 2
            median = (prices[mid - 1] + prices[mid]) / 2 if len(prices) % 2 == 0 else prices[mid]

            return {
                "low": round(prices[0], 2),
                "high": round(prices[-1], 2),
                "median": round(median, 2),
                "count": len(prices),
            }
    except Exception as e:
        print(f"[TCG] ERROR: {type(e).__name__}: {e}")
        return {"low": 0, "high": 0, "median": 0, "count": 0}


if __name__ == "__main__":
    import asyncio
    result = asyncio.run(get_prices("Charizard Base Set 4/102", "Pokemon"))
    print(result)
