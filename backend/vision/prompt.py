PROMPT = """Identify this second-hand or vintage item.
Return JSON only, no extra text:
{
    "category": "e.g. vinyl record / camera / handbag",
    "brand": "brand name or null",
    "condition": "excellent | good | fair | poor",
    "ebay_search": "optimized eBay search string"
}"""
