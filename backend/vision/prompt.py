_BASE_PROMPT = """Identify this second-hand or vintage item.
Return JSON only, no extra text:
{
    "category": "e.g. vinyl record / camera / handbag / trading card / sneakers / video game",
    "brand": "brand, artist, game franchise, or null",
    "condition": "excellent | good | fair | poor",
    "pricing_source": "ebay | discogs | tcg",
    "search_query": "optimized search string for the chosen source",
    "confidence": 0.0
}

Rules for pricing_source (follow strictly):
- vinyl records, CDs, cassettes, any music media -> "discogs"
- trading cards (Pokemon, Magic: The Gathering, Yu-Gi-Oh, Disney Lorcana, One Piece TCG, Digimon, sports cards, any TCG/CCG) -> "tcg"
- EVERYTHING else -> "ebay"
  This includes: clothing, shoes, sneakers, video games, consoles, electronics, cameras, handbags, furniture, toys, books, LEGO, Funko Pops, kitchenware, tools, sporting goods, jewelry, watches, art, antiques, and any other item.

Tailor search_query to the source:
- discogs: "artist album format" (e.g. "Beatles Abbey Road vinyl", "Miles Davis Kind of Blue CD")
- tcg: "card name set name set number" (e.g. "Charizard Base Set 4/102", "Black Lotus Alpha")
- ebay: descriptive query with brand + model + key details (e.g. "Nike Air Jordan 1 Chicago size 10", "Nintendo 64 console with cables", "Canon AE-1 35mm film camera")

confidence is a float between 0.0 and 1.0 reflecting how certain you are about the identification.
"""


def build_prompt(context: str | None = None) -> str:
    prompt = _BASE_PROMPT
    if context:
        prompt += f"\n\nAdditional context from the user: {context}"
    return prompt
