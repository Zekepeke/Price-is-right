PROMPT = """Identify this second-hand or vintage item.
Return JSON only, no extra text:
{
    "category": "e.g. vinyl record / camera / handbag / trading card",
    "brand": "brand, artist, or game name, or null",
    "condition": "excellent | good | fair | poor",
    "pricing_source": "ebay | discogs | tcg | other",
    "search_query": "optimized search string for the chosen source",
    "confidence": 0.0
}

Rules for pricing_source:
- vinyl, CDs, cassettes, music media -> "discogs"
- trading cards (Pokemon, MTG, Yu-Gi-Oh, sports) -> "tcg"
- anything else (clothing, electronics, housewares, toys) -> "ebay"

Tailor search_query to the source: 
- discogs: "artist album format" (e.g. "Beatles Abbey Road vinyl")
- tcg: "card name set number" (e.g. "Charizard Base Set 4/102")
- ebay: best-match query string with brand+model

confidence is a float between 0.0 and 1.0 reflecting how certain you are about the identification.
"""
