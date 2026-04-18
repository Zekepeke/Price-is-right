PROMPT = """Identify this second-hand or vintage item.
Return JSON only, no extra text:
{
    "category": "e.g. vinyl record / camera / handbag",
    "brand": "brand name or null",
    "condition": "excellent | good | fair | poor",
    "ebay_search": "optimized eBay search string",
    "confidence": 0.0
}
confidence is a float between 0.0 and 1.0 reflecting how certain you are about the identification."""
